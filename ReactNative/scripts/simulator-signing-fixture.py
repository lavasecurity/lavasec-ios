#!/usr/bin/env python3
"""Bind the isolated Debug simulator's public store namespace to Xcode's simulated entitlements."""
import json
import plistlib
import re
import sys
from pathlib import Path


def read_plist(path):
    return plistlib.loads(path.read_bytes())


def signing_fixture(derived):
    products = derived / 'Build/Products/Debug-iphonesimulator'
    intermediate = derived / 'Build/Intermediates.noindex/LavaSecRN.build/Debug-iphonesimulator'
    app = products / 'LavaSec.app'
    info = read_plist(app / 'Info.plist')
    bundle_id = info['CFBundleIdentifier']
    suffix = f'.{bundle_id}.chained-upstream'
    entitlements = read_plist(intermediate / 'LavaSec.build/LavaSec.app-Simulated.xcent')
    groups = entitlements.get('keychain-access-groups', [])
    shared = [group for group in groups if group.endswith(suffix)]
    if len(shared) != 1:
        raise ValueError('Exactly one simulated shared Keychain group is required.')
    prefix = shared[0][:-len(suffix)]
    if not re.fullmatch(r'[A-Z0-9]{10}', prefix):
        raise ValueError('Xcode must supply a qualified simulated signing prefix.')
    return products, intermediate, info, prefix, shared[0]


def main():
    mode, root = sys.argv[1:3]
    products, intermediate, info, prefix, group = signing_fixture(Path(root))
    if mode == 'prefix':
        print(prefix)
        return
    if mode != 'verify' or len(sys.argv) != 4:
        raise ValueError('Use prefix DERIVED or verify DERIVED RECEIPT.')
    if info.get('LavaKeychainSharingGroup') != group:
        raise ValueError('The app Info namespace must match its simulated signing entitlement.')
    tunnel = products / 'LavaSec.app/PlugIns/LavaSecTunnel.appex/Info.plist'
    tunnel_info = read_plist(tunnel)
    tunnel_entitlements = read_plist(intermediate / 'LavaSecTunnel.build/LavaSecTunnel.appex-Simulated.xcent')
    if tunnel_info.get('LavaKeychainSharingGroup') != group or group not in tunnel_entitlements.get('keychain-access-groups', []):
        raise ValueError('The app and tunnel must share the same simulated namespace.')
    for target, location in [('LavaSecWidget', 'PlugIns'), ('LavaSecIntents', 'Extensions')]:
        extension_info = read_plist(products / f'LavaSec.app/{location}/{target}.appex/Info.plist')
        extension_entitlements = read_plist(intermediate / f'{target}.build/{target}.appex-Simulated.xcent')
        if extension_info.get('LavaKeychainSharingGroup') or group in extension_entitlements.get('keychain-access-groups', []):
            raise ValueError('Widget and Intents must not receive the chained Keychain group.')
    receipt = {'result': 'Passed', 'scope': 'isolated Debug simulator only',
               'prefixSource': 'Xcode generated simulated entitlements',
               'appAndTunnelNamespaceMatches': True, 'widgetAndIntentsExcluded': True,
               'productionPolicyBypassed': False, 'deviceSigningQualified': False}
    Path(sys.argv[3]).write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
