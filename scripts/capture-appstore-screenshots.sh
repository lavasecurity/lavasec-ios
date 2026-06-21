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
# Add a 6.5" device if you want a dedicated set for older listings.
#
# Env overrides:
#   LAVA_APPSTORE_DEVICES   space-separated simulator names (default: "iPhone 16 Pro Max")
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
DEVICES=(${LAVA_APPSTORE_DEVICES:-iPhone 16 Pro Max})
LOCALES=(${LAVA_APPSTORE_LOCALES:-en ja zh-Hant zh-Hans de fr})
STATES=(${LAVA_APPSTORE_STATES:-protected})
# Deep-linked real screens (experimental — see scripts/appstore-screenshots.md).
DEEPLINK_SCREENS=(upgrade guard filters activity)

apple_locale() {
    case "$1" in
        en) echo "en_US" ;; ja) echo "ja_JP" ;;
        zh-Hant) echo "zh_TW" ;; zh-Hans) echo "zh_CN" ;;
        de) echo "de_DE" ;; fr) echo "fr_FR" ;;
        *) echo "$1" ;;
    esac
}

slug() { echo "$1" | tr '[:upper:] ' '[:lower:]-'; }

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
    xcrun simctl openurl "$1" "lavasecurity://$2" >/dev/null 2>&1 || true
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

    for locale in "${LOCALES[@]}"; do
        out="$OUTPUT_DIR/$locale"; mkdir -p "$out"
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
                echo "  [$locale] deeplink '$path'"
                launch_deeplink "$SIM_ID" "$path" "$locale" "$lv"
                printf -v n "%02d" "$idx"
                xcrun simctl io "$SIM_ID" screenshot \
                    "$out/${n}_${device_slug}_$(slug "$path").png" >/dev/null
            done
        fi
    done
done

echo "App Store screenshots written to $OUTPUT_DIR"
