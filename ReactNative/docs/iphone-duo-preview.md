# iPhone Duo previews

Duo's native vertical navigation requires an app linked with the iOS 27.1 SDK.
Running a 27.0-linked app on the 27.1 Simulator runtime does not qualify the
adaptive layout. Check the built product, rather than inferring its SDK from the
Simulator's device name or the installed Xcode application.

The app already uses `createNativeBottomTabNavigator` (a `UITabBarController`)
and native stacks. Keep those owners: UIKit chooses the rail edge and changes
between vertical and horizontal bars as the app's presentation changes. Retain
Guard and Settings, their labels, authorization and independent navigation state.
Do not add a custom right rail, force bottom positioning or fill the system's
reserved region with app content. Screens consume each safe-area edge separately
through the shared `Screen`; changes to insets belong there, with rendered evidence.

See Apple's [Duo guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo),
[Prepare your app](https://developer.apple.com/videos/play/tech-talks/111461/) and
[Raise the bar](https://developer.apple.com/videos/play/tech-talks/111462/), and the
[adaptive navigation PRD](https://github.com/lavasecurity/lavasec-infra/blob/main/plans/2026-10-18-iphone-duo-adaptive-navigation-prd.md).

## Build the complete app

Use the qualified toolchain from
[lavasec-runner](https://github.com/lavasecurity/lavasec-runner/blob/main/ci/qualified-xcode.json).
Selection is local to the shell/job; do not change global `xcode-select` for other
builds. With native Apple Silicon Node 24, Ruby 3.3.12, Bundler 4.0.16 and XcodeGen
2.45.4 on `PATH`, run from the root of a fresh dedicated checkout:

```bash
set -euo pipefail
duo_source_revision=$(git rev-parse --verify HEAD)
build_root=$(mktemp -d "${TMPDIR:-/tmp}/lava-duo.XXXXXX")
git worktree add --detach "$build_root/source" "$duo_source_revision"
cd "$build_root/source"
# Assert the fresh-start contract, including unexpected tracked overrides.
for sandbox in ReactNative/native-app/Pods ReactNative/native-app/build \
  ReactNative/native-app/.xcode.env ReactNative/native-app/.xcode.env.local; do
  if [ -e "$sandbox" ] || [ -L "$sandbox" ]; then
    echo 'Use a fresh checkout without an existing native Pods/build sandbox.' >&2
    exit 1
  fi
done
preview_local_config_manifest() {
  python3 - <<'PY'
import hashlib, json, re
from pathlib import Path
manifest = {}
for path in sorted(Path('Config').glob('*.local.xcconfig')):
    data = path.read_bytes()
    if path.is_symlink() or re.search(rb'^\s*#\s*include', data, re.MULTILINE):
        raise SystemExit('Use regular local xcconfig files without additional includes for this preview procedure.')
    manifest[str(path)] = hashlib.sha256(data).hexdigest()
print(json.dumps(manifest, sort_keys=True, indent=2))
PY
}
preview_source_phase=clean
verify_preview_source() {
  if [ "$preview_source_phase" = clean ]; then
    python3 ReactNative/scripts/verify-preview-source.py verify-clean "$duo_source_revision"
  else
    python3 ReactNative/scripts/verify-preview-source.py verify-prepared "$duo_source_revision" \
      "$build_root/evidence/wireguard-artifact-manifest.json"
  fi
  preview_local_config_manifest > "$build_root/current-local-config.json"
  cmp "$build_root/evidence/local-config.json" "$build_root/current-local-config.json"
}
mkdir -p "$build_root/evidence"
preview_local_config_manifest > "$build_root/evidence/local-config.json"
verify_preview_source
export DEVELOPER_DIR=/Applications/Xcode-27.1-RC.app/Contents/Developer
xcodebuild -version
xcrun --sdk iphonesimulator --show-sdk-version
bash ReactNative/scripts/prepare-full-app.sh "$build_root" "$build_root/evidence"
preview_source_phase=prepared
verify_preview_source
xcodebuild build \
  -workspace ReactNative/native-app/LavaSecRN.xcworkspace \
  -scheme LavaSec -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$build_root/DerivedData" \
  -clonedSourcePackagesDirPath "$build_root/SourcePackages" \
  -jobs 3 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  "LAVA_SOURCE_REVISION=$duo_source_revision"
verify_preview_source
```

The example creates a fresh detached worktree from the captured commit. Keep it
exclusive to this build. If native local configuration is needed, copy the
intended files into its `Config` directory before the initial manifest capture.
The fresh worktree excludes inherited Pods, generated sources and Xcode
environment scripts; matching lockfiles alone do not establish cached source
contents. The starting-state assertion checks that contract. Retain evidence
only if the later source/configuration checks pass: changes to the worktree or
its `HEAD` during preparation/build invalidate that attempt. The only permitted
tracked-file changes are the eight freshly source-built WireGuard outputs.
Preparation records their exact membership, hashes and file modes in
`wireguard-artifact-manifest.json`; the later checks reject additional outputs,
symlinks, staged changes and any alteration of those recorded bytes or modes.
Keep that manifest with the preview evidence. It identifies the engine and
toolchain actually used without requiring the historical snapshot to match a
different Xcode's output.

The commit identifies tracked source. The separate `local-config.json` manifest
identifies the ignored native configuration used by this build, including its
presence or absence, without copying credential values into evidence. The checks
reject configuration changes during preparation/build and local configuration
that adds further includes or follows symlinks. Retain this manifest with the
source revision and toolchain receipt as the build's combined provenance.

This is the full RN application with its native integrations and extensions.
The isolated review host is useful for component comparison but is insufficient
for Duo qualification. Simulator signing above is local ad-hoc signing; it does
not qualify device distribution or upload a build.

Before installation, retain `git rev-parse HEAD`, `xcodebuild -version`, the SDK
version and these keys from the app's `Info.plist` in
`$build_root/DerivedData/Build/Products/Debug-iphonesimulator/LavaSec.app`:

| Key | Expected for the current Duo toolchain |
| --- | --- |
| `DTSDKName` | `iphonesimulator27.1` |
| `DTXcodeBuild` | `27A9275` |
| `LavaSourceRevision` | The immutable source commit built above |

## Display and evidence

Install the iOS 27.1 Simulator runtime on the preview host, then select the actual
**iPhone Duo** profile in Xcode 27.1's DeviceHub. The runtime is a separate download
from Xcode's SDKs. Existing release archive hosts do not need that runtime merely
to build a device archive.

Reuse the dedicated light/dark preview devices without erasing their data. Set
appearance using `xcrun simctl ui DEVICE_UUID appearance light` (or `dark`), install
the full app and launch `com.lavasec.app`. First launch may show onboarding; retain
that distinction in evidence instead of presenting a gallery fixture as a live app.

Duo has multiple displays. Run `xcrun simctl io DEVICE_UUID enumerate` and capture
the active display explicitly, for example:

```bash
xcrun simctl io DEVICE_UUID screenshot --display=primary light.png
```

An inactive display can produce a black image even while the app is running.
Record which display and pose each image shows. Check both themes on outer
portrait/landscape and inner portrait/landscape, folding and resizing without
relaunching. Check Split View on each edge where available, tab/path/draft
retention, native protected navigation, long content and keyboard dismissal.
At the end of Guard's ordinary scroll, the final Explore row must remain
reachable without overlapping native controls.

Also check accessibility text sizes, VoiceOver, reduced motion/transparency,
right-to-left layout and the existing phone/tablet and deployment-floor matrix
in the PRD. A pair of settled screenshots establishes only those rendered states;
record unavailable checks and do not infer physical-device behavior from Simulator.
Signed release qualification additionally requires QA and production internal
archive/export dry runs of the same immutable source through lavasec-runner.
