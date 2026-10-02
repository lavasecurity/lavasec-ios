#!/usr/bin/env bash
# Run under ci/run-with-maintenance-lock.sh on self-hosted CI. Every generated
# native target, dependency, and executable build phase is checked before Xcode.
set -euo pipefail
# launchd-hosted runners can inherit an ASCII locale; CocoaPods requires UTF-8.
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
cd "$(dirname "$0")/.."
build_root=$(mktemp -d "${TMPDIR:-/tmp}/lava-ui-review.XXXXXX")
evidence="$PWD/.artifacts/review-host"
# xcresulttool refuses an existing attachment manifest. Start each invocation
# with fresh generated evidence so retries also cannot expose a previous ZIP.
rm -rf "$evidence"
mkdir -p "$evidence"
simulator_id=""
cleanup() {
  if [ -n "$simulator_id" ]; then
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$build_root"
}
trap cleanup EXIT

bash scripts/prepare-review-host.sh "$build_root" "$evidence"

# A private simulator prevents two runner jobs from sharing UI state. The trap
# deletes only this invocation's simulator, including on failure/cancellation.
xcrun simctl list runtimes --json > "$build_root/runtimes.json"
runtime=$(node -e 'const fs=require("fs"); const rs=JSON.parse(fs.readFileSync(process.argv[1])).runtimes.filter(r=>r.isAvailable && r.identifier.includes(".iOS-")); rs.sort((a,b)=>b.version.localeCompare(a.version,"en",{numeric:true})); if(!rs[0]) throw Error("An iOS simulator runtime is required"); process.stdout.write(rs[0].identifier);' "$build_root/runtimes.json")
simulator_id=$(xcrun simctl create "Lava UI Review ${GITHUB_RUN_ID:-local}" com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$runtime")
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b
bash scripts/test-native-containment.sh "$simulator_id" "$evidence"
started=$(date +%s)
xcodebuild -workspace ios/LavaSecUIReview.xcworkspace -scheme LavaSecUIReview -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_id" -parallel-testing-enabled NO \
  -derivedDataPath "$build_root/DerivedData" -resultBundlePath "$build_root/lifecycle.xcresult" \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES test > "$evidence/xcodebuild.log" 2>&1 || {
    if [ -d "$build_root/lifecycle.xcresult" ]; then
      xcrun xcresulttool get test-results summary --path "$build_root/lifecycle.xcresult" > "$evidence/test-summary.json" || true
      xcrun xcresulttool export attachments --path "$build_root/lifecycle.xcresult" --output-path "$evidence/screenshots" || true
    fi
    tail -n 100 "$evidence/xcodebuild.log"
    exit 1
  }
finished=$(date +%s)
echo "Build and lifecycle test elapsed seconds: $((finished - started))" > "$evidence/build-cost.txt"
xcrun xcresulttool get test-results summary --path "$build_root/lifecycle.xcresult" > "$evidence/test-summary.json"
xcrun xcresulttool export attachments --path "$build_root/lifecycle.xcresult" --output-path "$evidence/screenshots"
xcrun simctl spawn "$simulator_id" log show --last 15m --style json \
  --predicate 'subsystem == "com.lavasecurity.lavasec.ui-review" AND category == "runtime"' > "$evidence/runtime-metrics.json"
app="$build_root/DerivedData/Build/Products/Debug-iphonesimulator/LavaSecUIReview.app"
du -sk "$app" >> "$evidence/build-cost.txt"
ditto -c -k --sequesterRsrc --keepParent "$app" "$evidence/LavaSecUIReview-Simulator.zip"
