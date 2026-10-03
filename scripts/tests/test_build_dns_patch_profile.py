import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('builder', Path(__file__).resolve().parents[1] / 'build-dns-patch-profile.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class DNSPatchProfileTests(unittest.TestCase):
    def setUp(self):
        self.contract = json.loads(builder.CONTRACT.read_text())

    def test_all_domain_removable_dns_only_matches_app_contract(self):
        profile = builder.build_profile(self.contract)
        self.assertFalse(profile['PayloadRemovalDisallowed'])
        self.assertEqual(len(profile['PayloadContent']), 1)
        payload = profile['PayloadContent'][0]
        self.assertEqual(payload['PayloadType'], 'com.apple.dnsSettings.managed')
        settings = payload['DNSSettings']
        self.assertNotIn('SupplementalMatchDomains', settings)
        self.assertEqual(settings['ServerAddresses'], self.contract['serverAddresses'])
        self.assertEqual(settings['ServerName'], self.contract['serverName'])
        self.assertFalse(settings['AllowFailover'])
        self.assertEqual(settings['DNSProtocol'], 'TLS')

    def test_rebuild_preserves_identity_for_profile_replacement(self):
        first = builder.build_profile(self.contract)
        second = builder.build_profile(dict(self.contract, version=2))
        self.assertEqual(first['PayloadUUID'], second['PayloadUUID'])
        self.assertEqual(first['PayloadIdentifier'], second['PayloadIdentifier'])
        self.assertEqual(first['PayloadContent'][0]['PayloadUUID'], second['PayloadContent'][0]['PayloadUUID'])

    def test_rejects_gateway_and_unbounded_capture(self):
        for addresses in [[], ['192.168.1.1'], ['127.0.0.1'], ['9.9.9.10'] * 5]:
            with self.assertRaises(ValueError):
                builder.build_profile(dict(self.contract, serverAddresses=addresses))


if __name__ == '__main__':
    unittest.main()
