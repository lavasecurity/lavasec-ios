#!/usr/bin/env bash
# Shared credential-free preparation for full-app Simulator checks and signed QA device archives.
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
cd "$(dirname "$0")/.."
build_root="${1:?absolute temporary build directory required}"
evidence="${2:?absolute evidence directory required}"
[[ "$build_root" == /* && "$evidence" == /* ]] || { echo "Absolute paths required" >&2; exit 1; }
mkdir -p "$build_root" "$evidence"
export BUNDLE_PATH="$build_root/gems"
export BUNDLE_FROZEN=true
npm ci --ignore-scripts --no-audit --no-fund
npm test
node scripts/test-story-columns-layout.mjs | tee "$evidence/story-columns-layout.log"
npm run bundle:review
bundle install

expected='Version: 2.45.4'
if [ "$(xcodegen --version 2>/dev/null || true)" != "$expected" ]; then
  curl --fail --location --silent --show-error \
    'https://github.com/yonaskolb/XcodeGen/releases/download/2.45.4/xcodegen.zip' \
    --output "$build_root/xcodegen.zip"
  echo "090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef  $build_root/xcodegen.zip" | shasum -a 256 --check
  ditto -x -k "$build_root/xcodegen.zip" "$build_root/xcodegen"
  export PATH="$build_root/xcodegen/xcodegen/bin:$PATH"
fi
[ "$(xcodegen --version)" = "$expected" ]
shasum -a 256 ../project.yml ../LavaSec.xcodeproj/project.pbxproj > "$build_root/production-before.sha256"
ruby native-app/generate-project.rb
(cd native-app && bundle exec pod install --deployment)
python3 scripts/generate-rn-notices.py --check
bundle exec ruby scripts/inspect-full-app.rb > "$evidence/generated-graph.json"
node scripts/check-full-app.mjs "$evidence/generated-graph.json"
LAVA_FULL_APP_GRAPH="$evidence/generated-graph.json" node --test tests/full-app-policy.test.mjs
shasum -a 256 ../project.yml ../LavaSec.xcodeproj/project.pbxproj > "$build_root/production-after.sha256"
cmp "$build_root/production-before.sha256" "$build_root/production-after.sha256"
