#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


API_BASE = "https://api.appstoreconnect.apple.com/v1"
DEVELOPMENT_CERTIFICATE_TYPES = {"DEVELOPMENT", "IOS_DEVELOPMENT"}
DEVELOPMENT_PROFILE_TYPES = {"IOS_APP_DEVELOPMENT"}


@dataclass(frozen=True)
class CleanupPlan:
    certificate_ids: list[str]
    profile_ids: list[str]


def cleanup_plan(
    before: dict[str, Any],
    after: dict[str, Any],
    target_bundle_ids: set[str],
) -> CleanupPlan:
    before_certificate_ids = {item["id"] for item in before.get("certificates", [])}
    certificate_ids = [
        item["id"]
        for item in after.get("certificates", [])
        if item["id"] not in before_certificate_ids
        and item.get("attributes", {}).get("certificateType") in DEVELOPMENT_CERTIFICATE_TYPES
    ]

    before_profile_ids = {item["id"] for item in before.get("profiles", [])}
    profile_ids = [
        item["id"]
        for item in after.get("profiles", [])
        if item["id"] not in before_profile_ids
        and item.get("attributes", {}).get("profileType") in DEVELOPMENT_PROFILE_TYPES
        and _profile_matches_bundle_id(item, target_bundle_ids)
    ]

    return CleanupPlan(
        certificate_ids=sorted(certificate_ids),
        profile_ids=sorted(profile_ids),
    )


def _profile_matches_bundle_id(profile: dict[str, Any], target_bundle_ids: set[str]) -> bool:
    bundle_identifier = profile.get("bundleIdentifier")
    if bundle_identifier in target_bundle_ids:
        return True

    name = profile.get("attributes", {}).get("name", "")
    return any(bundle_id in name for bundle_id in target_bundle_ids)


class AppStoreConnectClient:
    def __init__(self, issuer_id: str, key_id: str, key_path: Path):
        self.issuer_id = issuer_id
        self.key_id = key_id
        self.key_path = key_path
        self._cached_token: str | None = None
        self._cached_token_expires_at = 0

    def get(self, path: str, query: dict[str, str] | None = None) -> dict[str, Any]:
        url = self._url(path, query)
        request = urllib.request.Request(url, headers=self._headers())
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read().decode("utf-8"))

    def delete(self, path: str) -> int:
        request = urllib.request.Request(path if path.startswith("https://") else f"{API_BASE}{path}")
        request.add_header("Authorization", f"Bearer {self._token()}")
        request.method = "DELETE"
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.status
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return 404
            raise

    def _url(self, path: str, query: dict[str, str] | None) -> str:
        url = f"{API_BASE}{path}"
        if query:
            url = f"{url}?{urllib.parse.urlencode(query)}"
        return url

    def _headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self._token()}"}

    def _token(self) -> str:
        now = int(time.time())
        if self._cached_token and self._cached_token_expires_at > now + 60:
            return self._cached_token

        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        payload = {
            "iss": self.issuer_id,
            "iat": now,
            "exp": now + 1200,
            "aud": "appstoreconnect-v1",
        }
        signing_input = ".".join(
            [
                _base64url(json.dumps(header, separators=(",", ":")).encode("utf-8")),
                _base64url(json.dumps(payload, separators=(",", ":")).encode("utf-8")),
            ]
        )
        signature = _sign_es256_with_openssl(self.key_path, signing_input.encode("utf-8"))
        token = f"{signing_input}.{_base64url(signature)}"
        self._cached_token = token
        self._cached_token_expires_at = now + 1200
        return token


def _base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _sign_es256_with_openssl(key_path: Path, signing_input: bytes) -> bytes:
    completed = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(key_path)],
        input=signing_input,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return _ecdsa_der_to_raw_rs(completed.stdout)


def _ecdsa_der_to_raw_rs(der: bytes) -> bytes:
    offset = 0
    if der[offset] != 0x30:
        raise ValueError("Expected ECDSA DER sequence")
    offset += 1
    sequence_length, offset = _read_der_length(der, offset)
    sequence_end = offset + sequence_length

    if der[offset] != 0x02:
        raise ValueError("Expected ECDSA R integer")
    offset += 1
    r_length, offset = _read_der_length(der, offset)
    r = der[offset : offset + r_length]
    offset += r_length

    if der[offset] != 0x02:
        raise ValueError("Expected ECDSA S integer")
    offset += 1
    s_length, offset = _read_der_length(der, offset)
    s = der[offset : offset + s_length]
    offset += s_length

    if offset != sequence_end:
        raise ValueError("Unexpected ECDSA DER trailing bytes")

    return _normalize_ec_integer(r) + _normalize_ec_integer(s)


def _read_der_length(der: bytes, offset: int) -> tuple[int, int]:
    length = der[offset]
    offset += 1
    if length < 0x80:
        return length, offset

    length_size = length & 0x7F
    value = int.from_bytes(der[offset : offset + length_size], "big")
    return value, offset + length_size


def _normalize_ec_integer(value: bytes) -> bytes:
    value = value.lstrip(b"\x00")
    if len(value) > 32:
        raise ValueError("ECDSA integer is too large for P-256")
    return value.rjust(32, b"\x00")


def collect_snapshot(client: AppStoreConnectClient, bundle_ids: set[str]) -> dict[str, Any]:
    bundle_id_map = _list_bundle_ids(client, bundle_ids)
    return {
        "certificates": _list_development_certificates(client),
        "profiles": _list_development_profiles(client, bundle_id_map),
    }


def _list_development_certificates(client: AppStoreConnectClient) -> list[dict[str, Any]]:
    certificates = _fetch_all(
        client,
        "/certificates",
        {
            "fields[certificates]": "name,certificateType,displayName,serialNumber,expirationDate",
            "limit": "200",
        },
    )
    return [
        item
        for item in certificates
        if item.get("attributes", {}).get("certificateType") in DEVELOPMENT_CERTIFICATE_TYPES
    ]


def _list_bundle_ids(client: AppStoreConnectClient, bundle_ids: set[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for bundle_id in sorted(bundle_ids):
        response = client.get(
            "/bundleIds",
            {
                "filter[identifier]": bundle_id,
                "fields[bundleIds]": "identifier",
                "limit": "200",
            },
        )
        for item in response.get("data", []):
            if item.get("attributes", {}).get("identifier") == bundle_id:
                result[item["id"]] = bundle_id
    return result


def _list_development_profiles(
    client: AppStoreConnectClient,
    bundle_id_map: dict[str, str],
) -> list[dict[str, Any]]:
    profiles = _fetch_all(
        client,
        "/profiles",
        {
            "fields[profiles]": "name,profileType,profileState,bundleId,uuid,createdDate,expirationDate",
            "filter[profileType]": "IOS_APP_DEVELOPMENT",
            "include": "bundleId",
            "limit": "200",
        },
    )

    filtered = []
    for profile in profiles:
        related_bundle_id = (
            profile.get("relationships", {})
            .get("bundleId", {})
            .get("data", {})
            .get("id")
        )
        bundle_identifier = bundle_id_map.get(related_bundle_id)
        if bundle_identifier:
            profile = dict(profile)
            profile["bundleIdentifier"] = bundle_identifier
            filtered.append(profile)
            continue

        name = profile.get("attributes", {}).get("name", "")
        if any(bundle_id in name for bundle_id in bundle_id_map.values()):
            filtered.append(profile)
    return filtered


def _fetch_all(
    client: AppStoreConnectClient,
    path: str,
    query: dict[str, str],
) -> list[dict[str, Any]]:
    response = client.get(path, query)
    data = list(response.get("data", []))
    next_url = response.get("links", {}).get("next")
    while next_url:
        response = client.get(next_url.removeprefix(API_BASE), None)
        data.extend(response.get("data", []))
        next_url = response.get("links", {}).get("next")
    return data


def write_snapshot(path: Path, snapshot: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(snapshot, indent=2, sort_keys=True), encoding="utf-8")


def read_snapshot(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Clean Xcode-created App Store Connect signing assets.")
    parser.add_argument("command", choices=["snapshot", "cleanup"])
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--key-path", required=True, type=Path)
    parser.add_argument("--state-dir", required=True, type=Path)
    parser.add_argument("--bundle-id", action="append", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    client = AppStoreConnectClient(args.issuer_id, args.key_id, args.key_path)
    bundle_ids = set(args.bundle_id)
    before_path = args.state_dir / "before-signing-assets.json"
    after_path = args.state_dir / "after-signing-assets.json"

    if args.command == "snapshot":
        snapshot = collect_snapshot(client, bundle_ids)
        write_snapshot(before_path, snapshot)
        print(
            "Captured signing asset snapshot: "
            f"{len(snapshot['certificates'])} development cert(s), "
            f"{len(snapshot['profiles'])} target development profile(s)."
        )
        return 0

    if not before_path.exists():
        print("No signing asset snapshot found; skipping cleanup to avoid deleting pre-existing assets.")
        return 0

    before = read_snapshot(before_path)
    after = collect_snapshot(client, bundle_ids)
    write_snapshot(after_path, after)
    plan = cleanup_plan(before, after, bundle_ids)

    print(
        "Signing asset cleanup plan: "
        f"{len(plan.profile_ids)} profile(s), {len(plan.certificate_ids)} certificate(s)."
    )

    for profile_id in plan.profile_ids:
        print(f"Deleting new development provisioning profile {profile_id}")
        if not args.dry_run:
            client.delete(f"/profiles/{profile_id}")

    for certificate_id in plan.certificate_ids:
        print(f"Revoking new development certificate {certificate_id}")
        if not args.dry_run:
            client.delete(f"/certificates/{certificate_id}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
