#!/usr/bin/env bash
# Caller supplies its own booted, isolated simulator. Never opens/resets Lava.
set -euo pipefail
# The extracted custom header was replaced by native navigation in Round 8.
echo "Retired historical harness: LavaFullSheetHeader no longer exists. Use the full-app shared-editor and closeout UI journeys; 78 historical checks are not current qualification." >&2
exit 2
cd "$(dirname "$0")/.."
simulator_id=${1:?Pass the isolated simulator UUID}
evidence=${2:?Pass the evidence directory}
mutation=${3:-none}
mkdir -p "$evidence"
evidence=$(cd "$evidence" && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/lava-native-sheet-layout.XXXXXX")
bundle_id=com.lavasecurity.lava.native-sheet-layout-tests
cleanup() {
  xcrun simctl uninstall "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
  rm -rf "$test_root"
}
trap cleanup EXIT
python3 scripts/extract-native-sheet-layout.py "$evidence/source" --mutation "$mutation"
app="$test_root/NativeSheetLayoutTests.app"
mkdir -p "$app"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.lavasecurity.lava.native-sheet-layout-tests</string>
<key>CFBundleExecutable</key><string>NativeSheetLayoutTests</string>
<key>CFBundleName</key><string>Native Sheet Layout Tests</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>MinimumOSVersion</key><string>18.0</string>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
arch=$(uname -m)
SDKROOT="$sdk" xcrun --sdk iphonesimulator swiftc -swift-version 6 -warnings-as-errors -sdk "$sdk" \
  -target "$arch-apple-ios18.0-simulator" -module-cache-path "$test_root/cache" \
  "$evidence/source/ProductionSheetLayout.swift" "$evidence/source/LavaTokens.swift" \
  "$evidence/source/LavaStrings.swift" "$evidence/source/LavaIconSize.swift" \
  tests/native-sheet-layout/NativeSheetLayoutTests.swift -o "$app/NativeSheetLayoutTests"
codesign --force --sign - "$app" >/dev/null
xcrun simctl install "$simulator_id" "$app"
launch_status=0
xcrun simctl launch --console "$simulator_id" "$bundle_id" > "$evidence/native-sheet-layout-console.log" 2>&1 || launch_status=$?
container=$(xcrun simctl get_app_container "$simulator_id" "$bundle_id" data)
cp "$container/Documents/results.json" "$evidence/native-sheet-layout-results.json"
python3 - "$evidence/native-sheet-layout-results.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(json.dumps({k: r[k] for k in ['passed', 'checks', 'failures']}, indent=2))
if not r['passed'] or r['checks'] != 78 or len(r['measurements']) != 6:
    sys.exit(1)
PY
exit "$launch_status"
