#!/usr/bin/env bash
# Run under ci/run-with-maintenance-lock.sh on self-hosted CI. Every generated
# native target, dependency, and executable build phase is checked before Xcode.
set -euo pipefail
# Routine CI compiles the complete app and executes the small UIKit regression
# app. Journey tours remain explicit; preserve the existing local default.
mode=${1:---journeys}
if [ "$#" -gt 1 ] || { [ "$mode" != --compile ] && [ "$mode" != --journeys ]; }; then
  echo "usage: build-full-app.sh [--compile|--journeys]" >&2
  exit 64
fi
# launchd-hosted runners can inherit an ASCII locale; CocoaPods requires UTF-8.
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
cd "$(dirname "$0")/.."
build_root=$(mktemp -d "${TMPDIR:-/tmp}/lava-rn-full.XXXXXX")
evidence="$PWD/.artifacts/full-app"
# xcresulttool refuses an existing attachment manifest. Start each invocation
# with fresh generated evidence so retries also cannot expose a previous ZIP.
rm -rf "$evidence"
mkdir -p "$evidence"
simulator_id=""
ipad_simulator_id=""
query_trace_pid=""
source scripts/simulator-cleanup.sh
cleanup() {
  if [ -n "$query_trace_pid" ]; then
    kill "$query_trace_pid" >/dev/null 2>&1 || true
    wait "$query_trace_pid" 2>/dev/null || true
  fi
  if [ -n "$simulator_id" ]; then
    cleanup_simulator "$simulator_id" "$evidence/simulator-cleanup.log"
  fi
  if [ -n "$ipad_simulator_id" ]; then
    cleanup_simulator "$ipad_simulator_id" "$evidence/simulator-cleanup.log"
  fi
  rm -rf "$build_root"
}
trap cleanup EXIT

bash scripts/prepare-full-app.sh "$build_root" "$evidence"

# A private simulator prevents two runner jobs from sharing UI state. The trap
# deletes only this invocation's simulator, including on failure/cancellation.
xcrun simctl list runtimes --json > "$build_root/runtimes.json"
runtime=$(node -e 'const fs=require("fs"); const rs=JSON.parse(fs.readFileSync(process.argv[1])).runtimes.filter(r=>r.isAvailable && r.identifier.includes(".iOS-")); rs.sort((a,b)=>b.version.localeCompare(a.version,"en",{numeric:true})); if(!rs[0]) throw Error("An iOS simulator runtime is required"); process.stdout.write(rs[0].identifier);' "$build_root/runtimes.json")
simulator_id=$(xcrun simctl create "Lava RN Full ${GITHUB_RUN_ID:-local}" com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$runtime")
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b
bash scripts/test-native-containment.sh "$simulator_id" "$evidence"
started=$(date +%s)
build_args=(-workspace native-app/LavaSecRN.xcworkspace -scheme LavaSec -configuration Debug
  -destination "platform=iOS Simulator,id=$simulator_id"
  -derivedDataPath "$build_root/DerivedData" -resultBundlePath "$build_root/lifecycle.xcresult"
  -jobs 3 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES)
if [ "$mode" = --journeys ]; then
  # Only the delayed-query DEBUG fixture emits these flags. Preserve its evidence
  # on failed tours without collecting query arguments, identities or results.
  xcrun simctl spawn "$simulator_id" log stream --style compact --level debug \
    --predicate 'eventMessage BEGINSWITH "LAVA_QUERY_"' > "$evidence/query-lifecycle.log" 2>&1 &
  query_trace_pid=$!
  build_args+=(-parallel-testing-enabled NO -only-testing:LavaSecUITests/RNFullAppUITests test)
else
  build_args+=(build)
fi
xcodebuild "${build_args[@]}" > "$evidence/xcodebuild.log" 2>&1 || {
    if [ "$mode" = --journeys ] && [ -d "$build_root/lifecycle.xcresult" ]; then
      xcrun xcresulttool get test-results summary --path "$build_root/lifecycle.xcresult" > "$evidence/test-summary.json" || true
      xcrun xcresulttool export attachments --path "$build_root/lifecycle.xcresult" --output-path "$evidence/screenshots" || true
    fi
    tail -n 100 "$evidence/xcodebuild.log"
    exit 1
  }
finished=$(date +%s)
echo "Validation ${mode#--} elapsed seconds: $((finished - started))" > "$evidence/build-cost.txt"
app="$build_root/DerivedData/Build/Products/Debug-iphonesimulator/LavaSec.app"
[ -d "$app" ] || { echo "Full app product missing" >&2; exit 1; }
du -sk "$app" >> "$evidence/build-cost.txt"
if [ "$mode" = --journeys ]; then
  xcrun xcresulttool get test-results summary --path "$build_root/lifecycle.xcresult" > "$evidence/test-summary.json"
  xcrun xcresulttool export attachments --path "$build_root/lifecycle.xcresult" --output-path "$evidence/screenshots"
  node -e 'const fs=require("fs");const s=JSON.parse(fs.readFileSync(process.argv[1]));if(s.result!=="Passed"||s.passedTests<14||s.failedTests!==0||s.skippedTests!==0)throw Error("Full-app journeys must execute and pass, with no skipped tests");' "$evidence/test-summary.json"

  # The same compiled app and UI-test bundle must also exercise an actual tablet.
  # Keep only one simulator booted, so the adaptive tour does not double runner
  # memory pressure. This second pass cannot silently rebuild another candidate.
  if [ -n "$query_trace_pid" ]; then
    kill "$query_trace_pid" >/dev/null 2>&1 || true
    wait "$query_trace_pid" 2>/dev/null || true
    query_trace_pid=""
  fi
  xcrun simctl shutdown "$simulator_id"
  xcrun simctl list devicetypes --json > "$build_root/device-types.json"
  ipad_type=$(node -e 'const fs=require("fs");const ds=JSON.parse(fs.readFileSync(process.argv[1])).devicetypes;const d=ds.find(d=>d.name.includes("iPad Pro")&&d.name.includes("11-inch")&&d.name.includes("M4"))??ds.find(d=>d.name.includes("iPad")&&d.name.includes("M"));if(!d)throw Error("An iPad simulator device type is required");process.stdout.write(d.identifier);' "$build_root/device-types.json")
  ipad_simulator_id=$(xcrun simctl create "Lava RN iPad ${GITHUB_RUN_ID:-local}" "$ipad_type" "$runtime")
  xcrun simctl boot "$ipad_simulator_id"
  xcrun simctl bootstatus "$ipad_simulator_id" -b
  mkdir -p "$evidence/ipad"
  ipad_started=$(date +%s)
  xcodebuild -workspace native-app/LavaSecRN.xcworkspace -scheme LavaSec -configuration Debug \
    -destination "platform=iOS Simulator,id=$ipad_simulator_id" \
    -derivedDataPath "$build_root/DerivedData" -resultBundlePath "$build_root/ipad.xcresult" \
    -parallel-testing-enabled NO \
    -only-testing:LavaSecUITests/RNFullAppUITests/testStoryJourneyLightPreservesConnectionAlignmentAcrossRotation \
    -only-testing:LavaSecUITests/RNFullAppUITests/testStoryJourneyDarkPreservesConnectionAlignmentAcrossRotation \
    test-without-building > "$evidence/ipad/xcodebuild.log" 2>&1 || {
      if [ -d "$build_root/ipad.xcresult" ]; then
        xcrun xcresulttool get test-results summary --path "$build_root/ipad.xcresult" > "$evidence/ipad/test-summary.json" || true
        xcrun xcresulttool export attachments --path "$build_root/ipad.xcresult" --output-path "$evidence/ipad/screenshots" || true
      fi
      tail -n 100 "$evidence/ipad/xcodebuild.log"
      exit 1
    }
  xcrun xcresulttool get test-results summary --path "$build_root/ipad.xcresult" > "$evidence/ipad/test-summary.json"
  xcrun xcresulttool export attachments --path "$build_root/ipad.xcresult" --output-path "$evidence/ipad/screenshots"
  node -e 'const fs=require("fs");const s=JSON.parse(fs.readFileSync(process.argv[1]));if(s.result!=="Passed"||s.passedTests!==2||s.failedTests!==0||s.skippedTests!==0)throw Error("Both iPad layout journeys must execute and pass, with no skipped tests");' "$evidence/ipad/test-summary.json"
  ipad_finished=$(date +%s)
  echo "Tablet test-without-building elapsed seconds: $((ipad_finished - ipad_started))" > "$evidence/ipad/build-cost.txt"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$evidence/Lava-RN-Full-Simulator.zip"
fi
# A compile receipt must never look like passing journey evidence. Routine runs
# retain the graph, build log and native scaffold results without a large app ZIP.
node -e 'const fs=require("fs");const [file,mode,elapsed]=process.argv.slice(1);fs.writeFileSync(file,JSON.stringify({mode,result:"Passed",elapsedSeconds:Number(elapsed),journeysExecuted:mode==="journeys"},null,2)+"\n");' \
  "$evidence/validation.json" "${mode#--}" "$((finished - started))"
