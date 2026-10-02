#!/usr/bin/env python3
"""Sign a reviewed DNS profile with a specific Keychain identity; never export its key.

Local CMS integrity checks do not establish iOS configuration-profile trust. Verify
the resulting installer on a device before publishing it. See the release plan.
"""

import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


def run(*arguments: str) -> bytes:
    return subprocess.run(arguments, check=True, capture_output=True).stdout


def fingerprint(certificate: Path) -> bytes:
    return run("openssl", "x509", "-in", str(certificate), "-noout", "-fingerprint", "-sha256").strip()


def verify_signed_profile(signed: Path, reviewed: bytes, certificate: Path) -> None:
    """Reject wrong signers even when the CMS signature itself is mathematically valid."""
    with tempfile.TemporaryDirectory(prefix="lava-profile-verify-") as temporary:
        signer = Path(temporary) / "signer.pem"
        # -noverify skips certificate-chain trust only, not the signature/content
        # check. iOS's profile trust policy is a separate device release gate.
        decoded = run("openssl", "cms", "-verify", "-inform", "DER", "-in", str(signed),
                      "-noverify", "-signer", str(signer))
        if decoded != reviewed:
            raise ValueError("Signed content differs from the reviewed profile")
        if signer.read_bytes().count(b"-----BEGIN CERTIFICATE-----") != 1:
            raise ValueError("Expected exactly one signing certificate")
        if fingerprint(signer) != fingerprint(certificate):
            raise ValueError("CMS was signed by a different certificate than requested")


def sign_dns_profile(source: Path, certificate: Path, output: Path) -> None:
    reviewed = source.read_bytes()
    profile = plistlib.loads(reviewed)
    if not isinstance(profile, dict) or profile.get("PayloadType") != "Configuration":
        raise ValueError("Input must be an unsigned configuration-profile plist")
    payloads = profile.get("PayloadContent")
    if not isinstance(payloads, list) or not payloads or any(
        not isinstance(payload, dict) or payload.get("PayloadType") != "com.apple.dnsSettings.managed"
        for payload in payloads
    ):
        raise ValueError("This signer accepts DNS-settings payloads only (no roots, MDM or VPN)")
    if profile.get("PayloadRemovalDisallowed", False):
        raise ValueError("The DNS profile must remain removable")
    if output.exists():
        raise ValueError("Output already exists; select a new artifact path")
    if certificate.read_bytes().count(b"-----BEGIN CERTIFICATE-----") != 1:
        raise ValueError("Pass the single public leaf certificate, without private keys or a chain")
    if b"PRIVATE KEY" in certificate.read_bytes():
        raise ValueError("Pass a public certificate only; keep the private key in Keychain")
    run("openssl", "x509", "-in", str(certificate), "-noout", "-checkend", "0")
    subject_key_id = run("openssl", "x509", "-in", str(certificate), "-noout",
                         "-ext", "subjectKeyIdentifier").decode()
    match = re.search(r"(?:[0-9A-Fa-f]{2}:)+[0-9A-Fa-f]{2}", subject_key_id)
    if not match:
        raise ValueError("Signing certificate has no Subject Key Identifier")
    # -N nickname selected a different identity in the device signing trial.
    # Select the public key ID, then independently pin the actual signer below.
    with tempfile.TemporaryDirectory(prefix=".lava-profile-", dir=output.parent) as temporary:
        temporary = Path(temporary)
        frozen = temporary / "reviewed.plist"
        frozen.write_bytes(reviewed)
        signed = temporary / "signed.mobileconfig"
        run("security", "cms", "-S", "-Z", match.group().replace(":", ""),
            "-H", "SHA256", "-G", "-u", "6", "-i", str(frozen), "-o", str(signed))
        verify_signed_profile(signed, reviewed, certificate)
        # Publish atomically without overwriting an existing reviewed artifact.
        os.link(signed, output)
    print(run("openssl", "x509", "-in", str(certificate), "-noout", "-subject", "-dates").decode().strip())
    print(f"Signed content and exact signer verified: {output}")
    print("iOS installer trust is still a required device check; this is not a Verified assertion.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="Reviewed unsigned DNS profile")
    parser.add_argument("--certificate", type=Path, required=True, help="Public leaf PEM for an identity already in Keychain")
    parser.add_argument("--output", type=Path, required=True, help="New signed .mobileconfig path")
    arguments = parser.parse_args()
    try:
        sign_dns_profile(arguments.input, arguments.certificate, arguments.output)
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Profile signing failed: {error}\n")


if __name__ == "__main__":
    main()
