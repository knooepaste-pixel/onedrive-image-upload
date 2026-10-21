import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


from examples import image_input


class IntegrationTests(unittest.TestCase):
    @patch('examples.image_input.subprocess.run')
    def test_image_part_uses_url_not_base64(self, run):
        run.side_effect = [
            subprocess.CompletedProcess([], 0, json.dumps({'status': 'ready', 'receiptPath': 'synthetic-receipt.json'})),
            subprocess.CompletedProcess([], 0, json.dumps({'status': 'ready', 'url': 'https://example.invalid/image?signature=synthetic'})),
        ]
        part, receipt = image_input.upload_image_part(Path('synthetic-image.png'))
        self.assertEqual(part['type'], 'image_url')
        self.assertTrue(part['image_url']['url'].startswith('https://'))
        self.assertEqual(receipt, 'synthetic-receipt.json')
        self.assertTrue(all(call.kwargs['capture_output'] for call in run.call_args_list))
        self.assertIn('-RevealUrl', run.call_args_list[-1].args[0])

    @patch('examples.image_input.subprocess.run')
    def test_remote_errors_are_not_exposed(self, run):
        run.return_value = subprocess.CompletedProcess([], 1, 'private response', 'private credential')
        with self.assertRaises(image_input.ImageUploadError) as raised:
            image_input.image_part_from_receipt('synthetic.json')
        self.assertNotIn('private response', str(raised.exception))
        self.assertNotIn('private credential', str(raised.exception))

    @patch('examples.image_input.subprocess.run')
    def test_timeout_does_not_echo_output(self, run):
        run.side_effect = subprocess.TimeoutExpired('helper', 180, output='private URL')
        with self.assertRaises(image_input.ImageUploadError) as raised:
            image_input.image_part_from_receipt('synthetic.json')
        self.assertNotIn('private URL', str(raised.exception))

    @patch('examples.image_input.subprocess.run')
    def test_http_url_rejected(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, json.dumps({'status': 'ready', 'url': 'http://example.invalid'}))
        with self.assertRaises(image_input.ImageUploadError):
            image_input.image_part_from_receipt('synthetic.json')


if __name__ == '__main__':
    unittest.main()
