#!/usr/bin/env python3
"""Collect licenses for Metro's shipped modules and CocoaPods' native libraries."""
import json, plistlib, re, sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
packages = {}
def sources(source_map):
    yield from source_map.get('sources', [])
    for section in source_map.get('sections', []):
        yield from sources(section['map'])

def visit(path):
    data = json.loads(path.read_text())
    key = data['name']+'@'+data['version']
    if key in packages: return
    texts = [file.read_text(errors='strict') for file in sorted(path.parent.iterdir()) if file.is_file() and re.match(r'^(license|licence|copying)([.\-_]|$)',file.name,re.I)]
    if not texts and data['name'].startswith("@react-native/") and data.get("license")=="MIT":
        texts = [(root/"node_modules/react-native/LICENSE").read_text()]
    if not texts and key == 'metro-runtime@0.87.0' and data.get('license') == 'MIT':
        # npm omits the monorepo license. Copy from the exact upstream tag:
        # https://raw.githubusercontent.com/react/metro/v0.87.0/LICENSE
        texts = [(root/'scripts/licenses/metro-0.87.0.txt').read_text()]
    if not texts: raise ValueError(f'Missing license text: {key}')
    packages[key] = '\n\n'.join(texts)
for source in sources(json.loads((root/'.artifacts/LavaUIReview.map').read_text())):
    if '/node_modules/' not in source:
        continue
    path = Path(source).resolve()
    if not path.is_relative_to(root/'node_modules'):
        raise ValueError(f'Unexpected bundle dependency path: {source}')
    # Nested package.json files (such as ESM module-type markers) need not identify
    # a package. Walk back to the actual name/version declaration.
    for directory in path.parents:
        manifest = directory/'package.json'
        if manifest.is_file():
            data = json.loads(manifest.read_text())
            if data.get('name') and data.get('version'):
                visit(manifest)
                break
    else:
        raise ValueError(f'Missing package manifest: {source}')
ack = root/'native-app/Pods/Target Support Files/Pods-LavaSec/Pods-LavaSec-acknowledgements.plist'
for item in plistlib.loads(ack.read_bytes()).get('PreferenceSpecifiers',[]):
    if item.get('Title') and item.get('FooterText'): packages['CocoaPods: '+item['Title']] = item['FooterText']
text = 'React Native presentation dependency notices\nGenerated from the installed, lockfile-pinned dependency licenses.\n\n' + '\n\n'.join(name+'\n'+'='*72+'\n'+value for name,value in sorted(packages.items()))
text = text.rstrip() + '\n'
output=root/'native-app/ReactNativeNotices.txt'
if '--check' in sys.argv:
    if output.read_text()!=text: raise ValueError('Regenerate ReactNativeNotices.txt after reviewing changed dependencies')
else: output.write_text(text)
print(f'RN notices: {len(packages)} dependency notices')
