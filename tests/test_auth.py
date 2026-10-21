import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch


SPEC = importlib.util.spec_from_file_location(
    'onedrive_auth', Path(__file__).resolve().parents[1] / 'scripts' / 'onedrive_auth.py'
)
auth = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(auth)


class AuthTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.login = auth.Login.__new__(auth.Login)
        self.login.root = Path(self.temp.name)
        self.login.selection = self.login.root / 'account.json'
        self.login.app = MagicMock()
        self.login.cache = MagicMock()
        self.login.cache.find.return_value = []
        self.account = {'home_account_id': 'test.consumer', 'realm': 'consumers'}
        self.result = {'access_token': 'synthetic-token', 'scope': auth.SCOPES[0]}

    def test_consumer_scope(self):
        self.assertEqual(self.login.validate(self.result, self.account), self.result)

    def test_qualified_scope(self):
        self.result['scope'] = 'https://graph.microsoft.com/Files.ReadWrite.AppFolder'
        self.assertIsNotNone(self.login.validate(self.result, self.account))

    def test_reject_business_account(self):
        with self.assertRaises(auth.AuthError):
            self.login.validate(self.result, {**self.account, 'realm': 'organization'})

    def test_reject_wrong_claim_tenant(self):
        self.result['id_token_claims'] = {'tid': 'organization'}
        with self.assertRaises(auth.AuthError):
            self.login.validate(self.result, self.account)

    def test_reject_missing_scope(self):
        self.result['scope'] = 'User.Read'
        with self.assertRaises(auth.AuthError):
            self.login.validate(self.result, self.account)

    def test_cached_result_without_claims_or_scope(self):
        del self.result['scope']
        self.login.cache.find.return_value = [{
            'secret': 'synthetic-token', 'home_account_id': 'test.consumer',
            'client_id': auth.CLIENT_ID, 'target': auth.SCOPES[0],
        }]
        self.assertIsNotNone(self.login.validate(self.result, self.account))

    def test_wrong_cached_client_rejected(self):
        del self.result['scope']
        self.login.cache.find.return_value = [{
            'secret': 'synthetic-token', 'home_account_id': 'test.consumer',
            'client_id': 'different-client', 'target': auth.SCOPES[0],
        }]
        with self.assertRaises(auth.AuthError):
            self.login.validate(self.result, self.account)

    def test_missing_token_returns_none(self):
        self.assertIsNone(self.login.validate({'error': 'login_required'}, self.account))

    def test_no_silent_account_switch(self):
        self.login.selection.write_text(json.dumps({'home_account_id': 'old-account'}))
        self.login.app.get_accounts.return_value = [self.account]
        with self.assertRaises(auth.AuthError):
            self.login.silent()
        self.login.app.acquire_token_silent.assert_not_called()

    def test_successful_silent_remembers_account(self):
        self.login.app.get_accounts.return_value = [self.account]
        self.login.app.acquire_token_silent.return_value = self.result
        self.assertEqual(self.login.silent(), self.result)
        self.assertEqual(json.loads(self.login.selection.read_text())['home_account_id'], 'test.consumer')

    def test_multiple_accounts_need_authorization(self):
        self.login.app.get_accounts.return_value = [self.account, {**self.account, 'home_account_id': 'second'}]
        self.assertIsNone(self.login.silent())

    def test_pending_device_flow_is_preserved(self):
        flow = {'expires_at': 9999999999, 'user_code': 'TEST'}
        self.login.app.acquire_token_by_device_flow.return_value = {'error': 'authorization_pending'}
        with patch.object(self.login, 'pending_flow', return_value=flow), patch.object(self.login, 'save_flow') as save:
            self.assertIsNone(self.login.complete())
            save.assert_called_once_with(flow)

    def test_rejected_device_flow_drops_pending_state(self):
        pending = self.login.root / 'pending-login.dpapi'
        pending.write_text('synthetic-state')
        self.login.app.acquire_token_by_device_flow.return_value = {'error': 'authorization_declined'}
        with patch.object(self.login, 'pending_flow', return_value={'expires_at': 9999999999}):
            with self.assertRaises(auth.AuthError):
                self.login.complete()
        self.assertFalse(pending.exists())

    def test_connect_returns_code_not_token(self):
        flow = {'verification_uri': 'https://example.invalid', 'user_code': 'TEST', 'expires_at': 9999999999}
        with patch.object(self.login, 'silent', return_value=None), patch.object(self.login, 'complete', return_value=None), patch.object(self.login, 'pending_flow', return_value=flow):
            result = self.login.connect()
        self.assertEqual(result['status'], 'authorization_pending')
        self.assertNotIn('access_token', result)

    def test_status_is_offline(self):
        result = auth.status(self.login.root)
        self.assertEqual(result['status'], 'authorization_required')
        self.assertFalse(result['encryptedCachePresent'])
        self.assertFalse(result['directoryWatcher'])


if __name__ == '__main__':
    unittest.main()
