#!/usr/bin/env bash
# Caller supplies its own isolated, booted simulator. No Lava app or user data is touched.
set -euo pipefail
cd "$(dirname "$0")/.."
simulator_id=${1:?Pass the isolated simulator UUID}
evidence=${2:?Pass the evidence directory}
mkdir -p "$evidence"
evidence=$(cd "$evidence" && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/lava-native-scaffold.XXXXXX")
bundle_id=com.lavasecurity.lava.native-scaffold-tests
cleanup() {
  xcrun simctl uninstall "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
  rm -rf "$test_root"
}
trap cleanup EXIT
app="$test_root/NativeScaffoldTests.app"
mkdir -p "$app"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.lavasecurity.lava.native-scaffold-tests</string>
<key>CFBundleExecutable</key><string>NativeScaffoldTests</string>
<key>CFBundleName</key><string>Native Scaffold Tests</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>MinimumOSVersion</key><string>18.0</string>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict>
<key>UIApplicationSupportsMultipleScenes</key><false/>
<key>UISceneConfigurations</key><dict/>
</dict>
</dict></plist>
PLIST
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
arch=$(uname -m)
xcrun --sdk iphonesimulator clang -fobjc-arc -Wall -Wextra -Werror -isysroot "$sdk" \
  -target "$arch-apple-ios18.0-simulator" -c ios/LavaSecUIReview/LavaControlTrackingGuard.m -o "$test_root/control-tracking.o"
xcrun --sdk iphonesimulator clang -fobjc-arc -Wall -Wextra -Werror -isysroot "$sdk" \
  -target "$arch-apple-ios18.0-simulator" -c tests/native-containment/NativeControlTrackingTests.m -o "$test_root/control-tracking-tests.o"
SDKROOT="$sdk" xcrun --sdk iphonesimulator swiftc -swift-version 6 -warnings-as-errors -sdk "$sdk" \
  -target "$arch-apple-ios18.0-simulator" -module-cache-path "$test_root/cache" \
  -import-objc-header tests/native-containment/NativeControlTrackingTests.h \
  ios/LavaSecUIReview/LavaNativeContainment.swift ios/LavaSecUIReview/LavaSymbolPalette.swift \
  ../LavaSecApp/LavaDesignSystem/LavaTokens.swift tests/native-containment/NativeContainmentTests.swift \
  "$test_root/control-tracking.o" "$test_root/control-tracking-tests.o" -o "$app/NativeScaffoldTests"
codesign --force --sign - "$app" >/dev/null
xcrun simctl install "$simulator_id" "$app"
# A failed assertion exits the test app nonzero. Preserve its report before
# the cleanup trap uninstalls the container, then propagate either failure.
launch_status=0
xcrun simctl launch --console "$simulator_id" "$bundle_id" > "$evidence/native-scaffold-console.log" 2>&1 || launch_status=$?
container=$(xcrun simctl get_app_container "$simulator_id" "$bundle_id" data)
cp "$container/Documents/results.json" "$evidence/native-scaffold-results.json"
node -e 'const fs=require("fs"); const r=JSON.parse(fs.readFileSync(process.argv[1])); console.log(r); if(!r.passed || r.checks < 60)process.exit(1);' "$evidence/native-scaffold-results.json"
exit "$launch_status"
