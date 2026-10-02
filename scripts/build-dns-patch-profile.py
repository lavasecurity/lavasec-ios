#!/usr/bin/env python3
"""Generate the removable all-domain DNS patch from the app's versioned contract.

Produces unsigned review input. Sign with sign-dns-profile.py before HTTPS delivery.
Never sets installation/protection state and never touches a phone or its VPN.
"""
import argparse
import ipaddress
import json
from pathlib import Path
import plistlib
import uuid

CONTRACT = Path(__file__).resolve().parents[1] / 'Sources/LavaSecKit/Resources/dns-patch-v1.json'


def build_profile(contract):
    addresses = contract['serverAddresses']
    if not addresses or len(addresses) > 4 or any(not ipaddress.ip_address(a).is_global for a in addresses):
        raise ValueError('DNS patch requires a bounded set of public literal addresses')
    identifier = contract['identifier']
    def payload(kind, suffix, name):
        identity = identifier + suffix
        return {'PayloadType': kind, 'PayloadVersion': 1, 'PayloadIdentifier': identity,
                'PayloadUUID': str(uuid.uuid5(uuid.NAMESPACE_URL, identity)).upper(),
                'PayloadDisplayName': name, 'PayloadOrganization': contract['organization']}
    dns = payload('com.apple.dnsSettings.managed', '.dns', contract['displayName'])
    dns['DNSSettings'] = {'DNSProtocol': 'TLS', 'ServerName': contract['serverName'],
                          'ServerAddresses': addresses, 'AllowFailover': False}
    # Omitted SupplementalMatchDomains selects all domains, including answer aliases.
    dns['OnDemandRules'] = [{'Action': 'Connect'}]
    profile = payload('Configuration', '', contract['displayName'])
    profile['PayloadRemovalDisallowed'] = False
    profile['PayloadDescription'] = (
        'Helps Lava filter DNS on Wi-Fi with Connectivity Assist. Requires matching '
        'DNS patch support enabled in Lava. When Guard is off, system DNS uses Quad9. '
        'A reconnect may briefly allow a lookup; existing connections can continue. '
        'Remove this profile in Settings to restore automatic system DNS.')
    profile['PayloadContent'] = [dns]
    return profile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    data = plistlib.dumps(build_profile(json.loads(CONTRACT.read_text())), sort_keys=True)
    with args.output.open('xb') as stream:
        stream.write(data)
    print(f'Unsigned profile for review: {args.output}')


if __name__ == '__main__':
    main()
