#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
IOS_DIR="$ROOT_DIR/apps/ios"
PROJECT_PATH="$IOS_DIR/LavaSec.xcodeproj"
SCHEME="${LAVA_CAPTURE_SCHEME:-LavaSec}"
CONFIGURATION="${LAVA_CAPTURE_CONFIGURATION:-Debug}"
BUNDLE_ID="${LAVA_CAPTURE_BUNDLE_ID:-com.lavasec.app}"
DEVICE_NAME="${LAVA_CAPTURE_DEVICE:-iPhone 16}"
DERIVED_DATA="${LAVA_CAPTURE_DERIVED_DATA:-$ROOT_DIR/.build/lava-site-capture-derived}"
OUTPUT_DIR="${LAVA_CAPTURE_OUTPUT_DIR:-$ROOT_DIR/server/site/lavasecurity-app/public/assets/app-captures}"
LOCALES=(${LAVA_CAPTURE_LOCALES:-en ja zh-Hant zh-Hans de fr})

apple_locale() {
    case "$1" in
        en) echo "en_US" ;;
        ja) echo "ja_JP" ;;
        zh-Hant) echo "zh_TW" ;;
        zh-Hans) echo "zh_CN" ;;
        de) echo "de_DE" ;;
        fr) echo "fr_FR" ;;
        *) echo "$1" ;;
    esac
}

python_first_available_sim() {
    /usr/bin/python3 - "$DEVICE_NAME" <<'PY'
import json
import subprocess
import sys

preferred_name = sys.argv[1]
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))

for runtime_devices in data.get("devices", {}).values():
    for device in runtime_devices:
        if device.get("state") == "Booted":
            print(device["udid"])
            raise SystemExit

for runtime_devices in data.get("devices", {}).values():
    for device in runtime_devices:
        if device.get("name") == preferred_name:
            print(device["udid"])
            raise SystemExit

for runtime_devices in data.get("devices", {}).values():
    for device in runtime_devices:
        if device.get("name", "").startswith("iPhone"):
            print(device["udid"])
            raise SystemExit

raise SystemExit(f"No available iPhone simulator found for {preferred_name!r}.")
PY
}

SIMULATOR_ID="${LAVA_CAPTURE_SIMULATOR_ID:-$(python_first_available_sim)}"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphonesimulator/LavaSec.app"

echo "Using simulator: $SIMULATOR_ID"
xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
open -a Simulator >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null

xcrun simctl status_bar "$SIMULATOR_ID" override \
    --time 20:05 \
    --dataNetwork 4g \
    --wifiMode inactive \
    --cellularBars 4 \
    --batteryState charged \
    --batteryLevel 89 >/dev/null 2>&1 || true

echo "Building $SCHEME ($CONFIGURATION)..."
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "id=$SIMULATOR_ID" \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet \
    CODE_SIGNING_ALLOWED=NO \
    build

echo "Installing $APP_PATH..."
xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"

mkdir -p "$OUTPUT_DIR"

for locale in "${LOCALES[@]}"; do
    locale_dir="$OUTPUT_DIR/$locale"
    mkdir -p "$locale_dir"
    locale_value="$(apple_locale "$locale")"

    echo "Capturing still for $locale..."
    xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID" \
        -lava-website-asset-capture \
        -lavaWebsiteCaptureState protected \
        -hasSeenLavaOnboarding YES \
        -AppleLanguages "($locale)" \
        -AppleLocale "$locale_value" >/dev/null
    sleep 2
    xcrun simctl io "$SIMULATOR_ID" screenshot "$locale_dir/guard-protected.png" >/dev/null

    echo "Capturing wake video for $locale..."
    xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID" \
        -lava-website-asset-capture \
        -lavaWebsiteCaptureState wake \
        -hasSeenLavaOnboarding YES \
        -AppleLanguages "($locale)" \
        -AppleLocale "$locale_value" >/dev/null
    sleep 0.2

    video_path="$locale_dir/guard-wake.mp4"
    rm -f "$video_path"
    xcrun simctl io "$SIMULATOR_ID" recordVideo --codec=h264 "$video_path" >/dev/null 2>&1 &
    recorder_pid=$!
    sleep 4
    kill -INT "$recorder_pid" >/dev/null 2>&1 || true
    wait "$recorder_pid" >/dev/null 2>&1 || true
done

echo "Website app captures written to $OUTPUT_DIR"
