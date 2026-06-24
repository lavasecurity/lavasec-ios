#!/usr/bin/env bash
# Capture App Store Connect screenshots at the required device sizes.
#
# Reuses the same launch-argument capture path as capture-website-assets.sh
# (-lava-website-asset-capture + -lavaWebsiteCaptureState), but targets the
# App Store device classes and writes a fastlane-friendly tree:
#
#   <out>/<locale>/<index>_<device-slug>_<screen>.png
#
# Required App Store sizes (one 6.9" set covers all modern iPhones; App Store
# Connect upscales it to 6.5"/6.7" listings):
#   - 6.9"  iPhone 16 Pro Max  → 1320 x 2868
# Add a 6.5" device (one name per line in LAVA_APPSTORE_DEVICES) for a dedicated set.
#
# Env overrides:
#   LAVA_APPSTORE_DEVICES   newline-separated simulator names (default: "iPhone 16 Pro Max")
#   LAVA_APPSTORE_LOCALES   space-separated locales        (default: en ja zh-Hant zh-Hans de fr)
#   LAVA_APPSTORE_STATES    website-capture states to shoot (default: "protected")
#   LAVA_APPSTORE_OUTPUT_DIR  output root (default: <ios>/fastlane/screenshots)
#   LAVA_APPSTORE_DEEPLINKS  "1" to also shoot real screens via deep links (experimental, see notes)
#   LAVA_APPSTORE_CONFIGURATION  build config (default: Debug)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"           # this script lives in <ios>/scripts
PROJECT_PATH="$IOS_DIR/LavaSec.xcodeproj"
SCHEME="${LAVA_APPSTORE_SCHEME:-LavaSec}"
CONFIGURATION="${LAVA_APPSTORE_CONFIGURATION:-Debug}"
BUNDLE_ID="${LAVA_APPSTORE_BUNDLE_ID:-com.lavasec.app}"
DERIVED_DATA="${LAVA_APPSTORE_DERIVED_DATA:-$IOS_DIR/.build/lava-appstore-derived}"
OUTPUT_DIR="${LAVA_APPSTORE_OUTPUT_DIR:-$IOS_DIR/fastlane/screenshots}"
# Simulator names contain spaces, so DEVICES is newline-delimited (one name per
# line), not space-separated — a space-split default would word-split
# "iPhone 16 Pro Max" into four bogus device names.
DEVICES=()
while IFS= read -r appstore_device; do
    if [[ -n "$appstore_device" ]]; then
        DEVICES+=("$appstore_device")
    fi
done <<< "${LAVA_APPSTORE_DEVICES:-iPhone 16 Pro Max}"
LOCALES=(${LAVA_APPSTORE_LOCALES:-en ja zh-Hant zh-Hans de fr})
STATES=(${LAVA_APPSTORE_STATES:-protected})
# Deep-linked real screens (experimental — see scripts/appstore-screenshots.md).
# settings/upgrade is the real route for the upgrade screen (bare "upgrade" doesn't resolve).
DEEPLINK_SCREENS=("settings/upgrade" guard filters activity)

# The website-asset capture screen is compiled only into DEBUG builds
# (LavaSecApp.swift: `#if DEBUG`), so a non-Debug configuration makes
# -lava-website-asset-capture a no-op and would silently screenshot the real
# production/onboarding flow instead of the curated Guard hero.
if [[ "$CONFIGURATION" != "Debug" ]]; then
    echo "LAVA_APPSTORE_CONFIGURATION=$CONFIGURATION: capture mode is Debug-only; aborting." >&2
    exit 1
fi

apple_locale() {
    case "$1" in
        en) echo "en_US" ;; ja) echo "ja_JP" ;;
        zh-Hant) echo "zh_TW" ;; zh-Hans) echo "zh_CN" ;;
        de) echo "de_DE" ;; fr) echo "fr_FR" ;;
        es) echo "es_ES" ;; ko) echo "ko_KR" ;;
        pt-BR) echo "pt_BR" ;; it) echo "it_IT" ;;
        *) echo "$1" ;;
    esac
}

# App Store Connect / fastlane deliver language codes. These differ from the app's
# locale codes: bare en/de/fr/es are rejected by deliver and must be regionalized;
# ja/zh-Hans/zh-Hant/ko/pt-BR/it are already valid ASC codes and pass through unchanged.
asc_locale() {
    case "$1" in
        en) echo "en-US" ;; de) echo "de-DE" ;; fr) echo "fr-FR" ;;
        es) echo "es-ES" ;;
        *) echo "$1" ;;
    esac
}

# Lowercase; collapse any run of non-alphanumerics to a single dash; trim dashes.
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//'; }

# Resolve (or create) a simulator UDID for an exact device name.
sim_udid_for() {
    /usr/bin/python3 - "$1" <<'PY'
import json, subprocess, sys
name = sys.argv[1]
data = json.loads(subprocess.check_output(
    ["xcrun", "simctl", "list", "devices", "available", "-j"]))
for devs in data.get("devices", {}).values():
    for d in devs:
        if d.get("name") == name:
            print(d["udid"]); raise SystemExit
# Not found: try to create it against the newest iOS runtime that offers the type.
types = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devicetypes", "-j"]))["devicetypes"]
dt = next((t for t in types if t["name"] == name), None)
runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "available", "-j"]))["runtimes"]
rt = next((r for r in reversed(runtimes) if r.get("isAvailable") and "iOS" in r.get("name", "")), None)
if dt and rt:
    print(subprocess.check_output(
        ["xcrun", "simctl", "create", name, dt["identifier"], rt["identifier"]]).decode().strip())
    raise SystemExit
sys.exit(f"No simulator named {name!r} and could not create one. "
         f"Add it in Xcode > Settings > Components or `xcrun simctl create`.")
PY
}

build_for() {
    local sim_id="$1"
    echo "Building $SCHEME ($CONFIGURATION)..."
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "id=$sim_id" \
        -derivedDataPath "$DERIVED_DATA" \
        -quiet \
        CODE_SIGNING_ALLOWED=NO \
        build
}

launch_capture_state() {  # sim, state, locale, apple_locale
    xcrun simctl terminate "$1" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$1" "$BUNDLE_ID" \
        -lava-website-asset-capture \
        -lavaWebsiteCaptureState "$2" \
        -hasSeenLavaOnboarding YES \
        -AppleLanguages "($3)" \
        -AppleLocale "$4" >/dev/null
    sleep 2
}

launch_deeplink() {  # sim, path, locale, apple_locale
    xcrun simctl terminate "$1" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$1" "$BUNDLE_ID" \
        -hasSeenLavaOnboarding YES \
        -AppleLanguages "($3)" \
        -AppleLocale "$4" >/dev/null
    sleep 1.5
    # openurl returns success at the OS level even when the in-app route is a no-op,
    # so a failed/unknown deep link can silently screenshot the previous screen —
    # surface OS-level failures and review deep-linked shots visually (see the doc).
    xcrun simctl openurl "$1" "lavasecurity://$2" >/dev/null \
        || echo "  WARN: openurl lavasecurity://$2 failed" >&2
    sleep 1.5
}

for device in "${DEVICES[@]}"; do
    SIM_ID="$(sim_udid_for "$device")"
    device_slug="$(slug "$device")"
    echo "== $device ($SIM_ID) =="
    xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
    open -a Simulator >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$SIM_ID" -b >/dev/null
    xcrun simctl status_bar "$SIM_ID" override \
        --time 09:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode notSupported --batteryState charged --batteryLevel 100 >/dev/null 2>&1 || true

    APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphonesimulator/LavaSec.app"
    build_for "$SIM_ID"
    xcrun simctl install "$SIM_ID" "$APP_PATH"

    # Remove this device's screenshots from a previous run across ALL existing
    # locale dirs (not only the ones this run visits), so narrowing
    # LAVA_APPSTORE_LOCALES or changing the state/deeplink set can't leave stale
    # PNGs behind for `fastlane deliver` to upload. Scoped to this device slug so
    # other devices' shots in the same tree are preserved.
    if [[ -d "$OUTPUT_DIR" ]]; then
        find "$OUTPUT_DIR" -type f -name "*_${device_slug}_*.png" -delete
    fi

    for locale in "${LOCALES[@]}"; do
        # Directory uses the App Store Connect language code so the tree drops into
        # `fastlane deliver` as-is; -AppleLocale below still uses the underscore form.
        out="$OUTPUT_DIR/$(asc_locale "$locale")"; mkdir -p "$out"
        lv="$(apple_locale "$locale")"
        idx=0

        for state in "${STATES[@]}"; do
            idx=$((idx+1))
            echo "  [$locale] capture-state '$state'"
            launch_capture_state "$SIM_ID" "$state" "$locale" "$lv"
            printf -v n "%02d" "$idx"
            xcrun simctl io "$SIM_ID" screenshot \
                "$out/${n}_${device_slug}_${state}.png" >/dev/null
        done

        if [[ "${LAVA_APPSTORE_DEEPLINKS:-0}" == "1" ]]; then
            for path in "${DEEPLINK_SCREENS[@]}"; do
                idx=$((idx+1))
                screen="${path##*/}"   # filename label = last route component (settings/upgrade → upgrade)
                echo "  [$locale] deeplink '$path'"
                launch_deeplink "$SIM_ID" "$path" "$locale" "$lv"
                printf -v n "%02d" "$idx"
                xcrun simctl io "$SIM_ID" screenshot \
                    "$out/${n}_${device_slug}_$(slug "$screen").png" >/dev/null
            done
        fi
    done
done

echo "App Store screenshots written to $OUTPUT_DIR"
