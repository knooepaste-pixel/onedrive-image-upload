---
name: onedrive-image-upload
description: Upload selected image inputs to personal OneDrive and obtain verified temporary HTTPS image URLs to reduce inline Base64 request size. Use for OneDrive image offload or image-related 413 errors, not whole-drive monitoring.
---

# OneDrive Image Upload

Resolve script paths relative to this file. Run `scripts/onedrive_image.ps1` with PowerShell 7.2+ on Windows. See [README.md](README.md) for installation and API examples; `scripts/install.ps1` installs dependencies but does not authorize an account.

- Run `-Action Status` first; cached login is not proof of connectivity. `-Action Verify` checks the app folder online and may provision it.
- For first-time authorization run `-Action Connect`, show the Microsoft verification URI/code to the user, and run Connect again after approval. Do not change the selected account, expand scopes or extract another application's credentials.
- Upload only task-selected images using `-Action Upload -Path <image>`. PNG/JPEG/WebP/GIF signatures and extensions are checked. Original bytes are preserved. No drive watcher or Codex transport interception is installed.
- Upload output contains a receipt path, not a signed URL. Use `-Action Refresh -ReceiptPath <receipt>` if submission is delayed. For integration privately capture `-Action Url -ReceiptPath <receipt> -RevealUrl`, parse its JSON and put `url` in the endpoint's documented image field. Never print the returned URL, raw SDK errors, token-helper output or receipts.
- Temporary URLs grant access to their image without login. They expire on Microsoft's schedule; refresh immediately before API submission. No permanent anonymous share is created. Remove only when the remote job has finished fetching, with `-Action Remove -ReceiptPath <receipt>`. Identical files share a remote item; deletion affects all jobs using it.
- Do not silently compress delivery masters, upload private evidence/customer documents, or scan unrelated files. Use small local previews for visual inspection.
- Confirm the actual provider supports remotely fetched images and does not re-embed Base64. A URL in prose does not provide vision to a text-only model. This helper reduces image payload size, not every source of 413 or existing oversized chat history.
- Offline acceptance: `scripts/test_onedrive_image.ps1` and `python -m unittest discover -s tests -v`. With explicit live-test scope, `scripts/test_live_onedrive.ps1` creates a synthetic image, checks cross-process login, anonymous full-file SHA256 and remote cleanup. No paid generation is required.

Runtime data stays outside the repository under `%LOCALAPPDATA%/Codex/onedrive-image-upload`; Windows DPAPI protects tokens and stored URLs. Never publish runtime data. A custom `ONEDRIVE_IMAGE_CLIENT_ID` uses a separate cache subtree. Do not run `scripts/onedrive_auth.py token` visibly: stdout contains a credential.
