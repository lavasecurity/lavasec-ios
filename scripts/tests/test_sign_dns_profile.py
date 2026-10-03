"""Exercise CMS integrity and signer selection with disposable local certificates."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "sign-dns-profile.py"
spec = importlib.util.spec_from_file_location("sign_dns_profile", SCRIPT)
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class ProfileSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        for name in ("company", "wrong"):
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(cls.root / f"{name}.key"),
                "-out", str(cls.root / f"{name}.pem"), "-days", "1",
                "-subj", f"/CN={name}/O=Local test only",
            ], check=True, capture_output=True)
        cls.content = b"<plist><dict><key>PayloadType</key><string>Configuration</string></dict></plist>"
        (cls.root / "input.plist").write_bytes(cls.content)
        for name in ("company", "wrong"):
            subprocess.run([
                "openssl", "cms", "-sign", "-binary", "-nodetach", "-md", "sha256",
                "-in", str(cls.root / "input.plist"), "-signer", str(cls.root / f"{name}.pem"),
                "-inkey", str(cls.root / f"{name}.key"), "-outform", "DER",
                "-out", str(cls.root / f"{name}.mobileconfig"),
            ], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_accepts_intact_content_and_the_exact_certificate(self):
        signing.verify_signed_profile(self.root / "company.mobileconfig", self.content, self.root / "company.pem")

    def test_rejects_valid_signature_by_a_different_identity(self):
        with self.assertRaisesRegex(ValueError, "different certificate"):
            signing.verify_signed_profile(self.root / "wrong.mobileconfig", self.content, self.root / "company.pem")

    def test_rejects_content_that_differs_from_the_reviewed_profile(self):
        with self.assertRaisesRegex(ValueError, "content differs"):
            signing.verify_signed_profile(self.root / "company.mobileconfig", self.content + b"\n", self.root / "company.pem")

    def test_rejects_tampered_signed_content(self):
        original = (self.root / "company.mobileconfig").read_bytes()
        self.assertIn(b"Configuration", original)
        tampered = self.root / "tampered.mobileconfig"
        tampered.write_bytes(original.replace(b"Configuration", b"ConfiguratioX", 1))
        with self.assertRaises(subprocess.CalledProcessError):
            signing.verify_signed_profile(tampered, self.content, self.root / "company.pem")


if __name__ == "__main__":
    unittest.main()
