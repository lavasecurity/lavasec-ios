import unittest
from pathlib import Path
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import apple_signing_cleanup
from apple_signing_cleanup import AppStoreConnectClient, cleanup_plan


class SigningCleanupPlanTests(unittest.TestCase):
    def test_deletes_only_new_development_certificates(self):
        before = {
            "certificates": [
                {"id": "existing-dev", "attributes": {"certificateType": "DEVELOPMENT"}},
            ],
            "profiles": [],
        }
        after = {
            "certificates": [
                {"id": "existing-dev", "attributes": {"certificateType": "DEVELOPMENT"}},
                {"id": "new-dev", "attributes": {"certificateType": "IOS_DEVELOPMENT"}},
                {"id": "new-dist", "attributes": {"certificateType": "IOS_DISTRIBUTION"}},
            ],
            "profiles": [],
        }

        plan = cleanup_plan(before, after, {"com.lavasec.app"})

        self.assertEqual(plan.certificate_ids, ["new-dev"])

    def test_deletes_only_new_development_profiles_for_target_bundle_ids(self):
        before = {
            "certificates": [],
            "profiles": [
                {
                    "id": "existing-profile",
                    "attributes": {"profileType": "IOS_APP_DEVELOPMENT"},
                    "bundleIdentifier": "com.lavasec.app",
                },
            ],
        }
        after = {
            "certificates": [],
            "profiles": [
                {
                    "id": "existing-profile",
                    "attributes": {"profileType": "IOS_APP_DEVELOPMENT"},
                    "bundleIdentifier": "com.lavasec.app",
                },
                {
                    "id": "new-qa-profile",
                    "attributes": {"profileType": "IOS_APP_DEVELOPMENT"},
                    "bundleIdentifier": "com.lavasec.app",
                },
                {
                    "id": "new-tunnel-profile",
                    "attributes": {"profileType": "IOS_APP_DEVELOPMENT"},
                    "bundleIdentifier": "com.lavasec.app.tunnel",
                },
                {
                    "id": "new-other-profile",
                    "attributes": {"profileType": "IOS_APP_DEVELOPMENT"},
                    "bundleIdentifier": "com.example.other",
                },
                {
                    "id": "new-app-store-profile",
                    "attributes": {"profileType": "IOS_APP_STORE"},
                    "bundleIdentifier": "com.lavasec.app",
                },
            ],
        }

        plan = cleanup_plan(
            before,
            after,
            {"com.lavasec.app", "com.lavasec.app.tunnel"},
        )

        self.assertEqual(
            plan.profile_ids,
            ["new-qa-profile", "new-tunnel-profile"],
        )

    def test_falls_back_to_profile_name_when_bundle_relationship_is_missing(self):
        before = {"certificates": [], "profiles": []}
        after = {
            "certificates": [],
            "profiles": [
                {
                    "id": "new-profile",
                    "attributes": {
                        "name": "iOS Team Provisioning Profile: com.lavasec.app",
                        "profileType": "IOS_APP_DEVELOPMENT",
                    },
                },
            ],
        }

        plan = cleanup_plan(before, after, {"com.lavasec.app"})

        self.assertEqual(plan.profile_ids, ["new-profile"])

    def test_app_store_connect_token_is_reused_until_near_expiration(self):
        client = AppStoreConnectClient("issuer", "key-id", Path("AuthKey_test.p8"))
        signatures = []

        def fake_sign(_key_path, signing_input):
            signatures.append(signing_input)
            return bytes([len(signatures)]) * 64

        with patch.object(apple_signing_cleanup, "_sign_es256_with_openssl", side_effect=fake_sign), \
             patch.object(apple_signing_cleanup.time, "time", side_effect=[1000, 1050, 2141]):
            first = client._token()
            second = client._token()
            third = client._token()

        self.assertEqual(first, second)
        self.assertNotEqual(second, third)
        self.assertEqual(len(signatures), 2)


if __name__ == "__main__":
    unittest.main()
