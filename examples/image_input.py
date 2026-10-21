"""Build a Chat Completions remote-image part without logging signed URLs.

Import this module from an API integration. It never submits an AI request.
The actual model/provider must support the image_url content-part schema.
"""
import json
from pathlib import Path
import subprocess

HELPER = Path(__file__).resolve().parents[1] / "scripts" / "onedrive_image.ps1"


class ImageUploadError(RuntimeError):
    pass


def _call(*arguments):
    try:
        completed = subprocess.run(
            ["pwsh.exe", "-NoProfile", "-File", str(HELPER), *map(str, arguments)],
            capture_output=True, text=True, encoding="utf-8", timeout=180, check=False,
        )
        if completed.returncode:
            raise ImageUploadError("OneDrive helper failed; raw output is intentionally suppressed")
        result = json.loads(completed.stdout)
        if result.get("status") != "ready":
            raise ImageUploadError("Image is not ready")
        return result
    except (OSError, subprocess.TimeoutExpired, ValueError):
        raise ImageUploadError("OneDrive helper failed; no raw output is logged") from None


def image_part_from_receipt(receipt_path):
    """Refresh just before submission. Never log or print the returned object."""
    result = _call("-Action", "Url", "-ReceiptPath", Path(receipt_path).resolve(), "-RevealUrl")
    url = result.get("url", "")
    if not url.startswith("https://"):
        raise ImageUploadError("Expected a verified HTTPS image URL")
    return {"type": "image_url", "image_url": {"url": url}}


def upload_image_part(image_path):
    """Return (private image part, local receipt path); upload only selected inputs."""
    uploaded = _call("-Action", "Upload", "-Path", Path(image_path).resolve())
    receipt_path = uploaded["receiptPath"]
    return image_part_from_receipt(receipt_path), receipt_path
