"""Resumable Microsoft device login with a Windows DPAPI-protected MSAL cache."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import time

import msal
from msal_extensions import FilePersistenceWithDataProtection, PersistedTokenCache

DEFAULT_CLIENT_ID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"  # Microsoft Graph Command Line Tools
CLIENT_ID = os.environ.get("ONEDRIVE_IMAGE_CLIENT_ID", DEFAULT_CLIENT_ID).lower()
if not re.fullmatch(r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}", CLIENT_ID):
    raise ValueError("ONEDRIVE_IMAGE_CLIENT_ID must be a public application UUID")
TENANT = "9188040d-6c67-4c5b-b112-36a304b66dad"
SCOPES = ["Files.ReadWrite.AppFolder"]
ROOT = Path(os.environ["LOCALAPPDATA"]) / "Codex" / "onedrive-image-upload"
if CLIENT_ID != DEFAULT_CLIENT_ID:
    ROOT = ROOT / "clients" / CLIENT_ID


class AuthError(Exception):
    pass


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    import uuid
    temp = path.with_name(f".{path.name}-{uuid.uuid4().hex}.tmp")
    try:
        temp.write_text(json.dumps(value), encoding="utf-8")
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


class Login:
    def __init__(self, root=ROOT):
        if os.name != "nt":
            raise AuthError("windows_dpapi_required")
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.pending = FilePersistenceWithDataProtection(str(self.root / "pending-login.dpapi"))
        self.cache = PersistedTokenCache(
            FilePersistenceWithDataProtection(str(self.root / "msal-cache.dpapi"))
        )
        self.app = msal.PublicClientApplication(
            CLIENT_ID, authority="https://login.microsoftonline.com/consumers",
            token_cache=self.cache, timeout=30, enable_broker_on_windows=False,
        )
        self.selection = self.root / "account.json"

    def pending_flow(self):
        if not (self.root / "pending-login.dpapi").exists():
            return None
        flow = json.loads(self.pending.load())
        return flow if flow.get("expires_at", 0) > time.time() else None

    def save_flow(self, flow):
        self.pending.save(json.dumps(flow))

    def selected_account(self):
        if not self.selection.exists():
            return None
        selected = json.loads(self.selection.read_text(encoding="utf-8"))
        return next((account for account in self.app.get_accounts()
                     if account.get("home_account_id") == selected.get("home_account_id")), None)

    def validate(self, result, account):
        if not result or "access_token" not in result:
            return None
        claims = result.get("id_token_claims", {})
        if account.get("realm") not in {TENANT, "consumers"} or (claims.get("tid") and claims["tid"] != TENANT):
            raise AuthError("personal_account_required")
        granted = set(result.get("scope", "").split())
        if not granted:
            # MSAL cache hits can omit both scope and ID-token claims for consumer accounts.
            for token in self.cache.find("AccessToken"):
                if (token.get("secret") == result["access_token"]
                        and token.get("home_account_id") == account.get("home_account_id")
                        and token.get("client_id", "").lower() == CLIENT_ID):
                    granted.update(token.get("target", "").split())
        if not any(scope.lower().split("/")[-1] == "files.readwrite.appfolder" for scope in granted):
            raise AuthError("appfolder_scope_missing")
        return result

    def silent(self):
        account = self.selected_account()
        if not account:
            if self.selection.exists():
                raise AuthError("selected_account_missing_reauthorize_explicitly")
            accounts = [candidate for candidate in self.app.get_accounts()
                        if candidate.get("realm") in {TENANT, "consumers"}]
            if len(accounts) != 1:
                return None
            account = accounts[0]
        result = self.validate(self.app.acquire_token_silent(SCOPES, account=account), account)
        if result:
            self.remember(account)
        return result

    def remember(self, account):
        write_json(self.selection, {"home_account_id": account["home_account_id"], "tenant": TENANT})
        (self.root / "pending-login.dpapi").unlink(missing_ok=True)

    def complete(self):
        flow = self.pending_flow()
        if not flow:
            return None
        result = self.app.acquire_token_by_device_flow(flow, exit_condition=lambda _: True)
        if result.get("error") in {"authorization_pending", "slow_down"}:
            self.save_flow(flow)
            return None
        if "access_token" not in result:
            (self.root / "pending-login.dpapi").unlink(missing_ok=True)
            code = result.get("error", "authorization_failed")
            raise AuthError(code if re.fullmatch(r"[a-zA-Z0-9_]+", code) else "authorization_failed")
        claims = result.get("id_token_claims", {})
        accounts = [account for account in self.app.get_accounts()
                    if account.get("realm") in {TENANT, "consumers"}
                    and (not claims.get("oid") or account.get("local_account_id") == claims["oid"])]
        if len(accounts) != 1:
            raise AuthError("authorized_account_not_found")
        self.validate(result, accounts[0])
        self.remember(accounts[0])
        return result

    def connect(self):
        result = self.silent() or self.complete()
        if result:
            return {"status": "authorized", "personalAccount": True, "scope": SCOPES[0]}
        flow = self.pending_flow()
        if not flow:
            flow = self.app.initiate_device_flow(scopes=SCOPES)
            if "user_code" not in flow:
                raise AuthError("device_login_start_failed")
            self.save_flow(flow)
        return {"status": "authorization_pending", "verificationUri": flow["verification_uri"],
                "userCode": flow["user_code"], "expiresInSeconds": max(0, int(flow["expires_at"] - time.time()))}

    def token(self):
        result = self.silent() or self.complete()
        if not result:
            raise AuthError("authorization_required_run_connect")
        return {"status": "authorized", "personalAccount": True, "scope": SCOPES[0],
                "access_token": result["access_token"]}


def status(root=ROOT):
    root = Path(root)
    return {"status": "cached_login_unverified" if (root / "account.json").exists() else
            "authorization_pending" if (root / "pending-login.dpapi").exists() else "authorization_required",
            "encryptedCachePresent": (root / "msal-cache.dpapi").exists(),
            "clientId": CLIENT_ID,
            "directoryWatcher": False, "storageRoot": str(root)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["status", "connect", "token"])
    args = parser.parse_args()
    try:
        if args.action == "status":
            result = status()
        else:
            login = Login()
            result = login.connect() if args.action == "connect" else login.token()
        print(json.dumps(result, separators=(",", ":")), flush=True)
        return 0
    except AuthError as error:
        print(json.dumps({"status": "failed", "error": str(error)}), flush=True)
    except Exception as error:
        # Exception bodies can contain credentials; expose only the class name.
        print(json.dumps({"status": "failed", "errorType": type(error).__name__}), flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
