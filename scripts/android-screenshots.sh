#!/usr/bin/env bash
# Play listing images from the built-in demo.
#   1. Phone screenshots: runs integration_test/demo_flow_test.dart on an Android
#      emulator (the first AVD, booted without a snapshot) and copies the PNGs into
#      app/android/fastlane/metadata/android/en-US/images/phoneScreenshots/.
#   2. icon.png (512x512) and featureGraphic.png (1024x500, icon centered on the
#      brand background) from app/assets/icon/icon.svg, with rsvg-convert or
#      ImageMagick, into .../images/.
# Needs: flutter; for 1. an Android SDK with the emulator and one AVD; for 2.
# rsvg-convert (librsvg) or magick/convert (ImageMagick). Each part is skipped
# with a message when its tool is missing.
#   scripts/android-screenshots.sh            both parts
#   scripts/android-screenshots.sh --images   only the icon and feature graphic
#   scripts/android-screenshots.sh --shots    only the screenshots
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
APP=$ROOT/app
IMAGES=$APP/android/fastlane/metadata/android/en-US/images
SHOTS=$IMAGES/phoneScreenshots
ICON_SVG=$APP/assets/icon/icon.svg

do_shots=1; do_images=1
case "${1:-}" in
  --images) do_shots=0 ;;
  --shots) do_images=0 ;;
  "") ;;
  *) echo "usage: $0 [--images|--shots]" >&2; exit 2 ;;
esac

images() {
  mkdir -p "$IMAGES"
  # Brand background: the full-size rect at the top of the icon SVG.
  local bg
  bg=$(grep -o '<rect width="1024" height="1024" fill="#[0-9A-Fa-f]*"' "$ICON_SVG" | grep -o '#[0-9A-Fa-f]*' | head -1)
  bg=${bg:-#000000}
  if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w 512 -h 512 "$ICON_SVG" -o "$IMAGES/icon.png"
    # Feature graphic: 1024x500 background with the icon's drawing nested in the middle.
    local inner
    inner=$(sed -e 's/<?xml[^>]*?>//' -e 's/<svg[^>]*>//' -e 's#</svg>##' "$ICON_SVG")
    {
      printf '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="500" viewBox="0 0 1024 500">\n'
      printf '<rect width="1024" height="500" fill="%s"/>\n' "$bg"
      printf '<svg x="312" y="50" width="400" height="400" viewBox="0 0 1024 1024">\n%s\n</svg>\n</svg>\n' "$inner"
    } > "$IMAGES/featureGraphic.svg"
    rsvg-convert -w 1024 -h 500 "$IMAGES/featureGraphic.svg" -o "$IMAGES/featureGraphic.png"
    rm -f "${IMAGES:?}/featureGraphic.svg"
  elif command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; then
    local im
    im=$(command -v magick || command -v convert)
    "$im" -background none -density 192 "$ICON_SVG" -resize 512x512 "$IMAGES/icon.png"
    "$im" -size 1024x500 "xc:$bg" \( -background none -density 192 "$ICON_SVG" -resize 400x400 \) -gravity center -composite "$IMAGES/featureGraphic.png"
  else
    echo "icon/feature graphic skipped: install librsvg (rsvg-convert) or ImageMagick (magick)" >&2
    return 0
  fi
  echo "wrote $IMAGES/icon.png (512x512) and $IMAGES/featureGraphic.png (1024x500)"
}

shots() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  local emu="$sdk/emulator/emulator"
  if [ -z "$sdk" ] || [ ! -x "$emu" ]; then
    cat >&2 <<MSG
screenshots skipped: no Android emulator at \$ANDROID_HOME/emulator/emulator.
Install the Android SDK with the "Android Emulator" and a system image, then create an AVD:
  sdkmanager "emulator" "platform-tools" "system-images;android-35;google_apis;x86_64"
  avdmanager create avd -n porthole -k "system-images;android-35;google_apis;x86_64" -d pixel_8
MSG
    return 0
  fi
  local avd
  avd=$("$emu" -list-avds 2>/dev/null | grep -v '^INFO' | head -1 || true)
  if [ -z "$avd" ]; then
    cat >&2 <<MSG
screenshots skipped: no AVD. Create one (a phone profile; Play wants phone-sized shots):
  avdmanager create avd -n porthole -k "system-images;android-35;google_apis;x86_64" -d pixel_8
MSG
    return 0
  fi
  local adb="$sdk/platform-tools/adb"
  [ -x "$adb" ] || adb=adb
  echo "booting AVD $avd"
  "$emu" -avd "$avd" -no-snapshot -no-boot-anim -no-audio -netdelay none -netspeed full >/dev/null 2>&1 &
  local emu_pid=$!
  local serial="" i
  trap '"$adb" -s "${serial:-emulator-5554}" emu kill >/dev/null 2>&1 || kill $emu_pid 2>/dev/null || true' EXIT
  for i in $(seq 1 60); do
    serial=$("$adb" devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')
    [ -n "$serial" ] && break
    sleep 2
  done
  [ -n "$serial" ] || { echo "emulator did not come up" >&2; return 1; }
  for i in $(seq 1 90); do
    [ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    sleep 2
  done
  # Clean status bar for the shots (demo mode: 9:41, full battery, wifi, no notifications).
  "$adb" -s "$serial" shell settings put global sysui_demo_allowed 1
  "$adb" -s "$serial" shell am broadcast -a com.android.systemui.demo -e command enter >/dev/null
  "$adb" -s "$serial" shell am broadcast -a com.android.systemui.demo -e command clock -e hhmm 0941 >/dev/null
  "$adb" -s "$serial" shell am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false >/dev/null
  "$adb" -s "$serial" shell am broadcast -a com.android.systemui.demo -e command network -e wifi show -e level 4 -e mobile show -e datatype none -e level 4 >/dev/null
  "$adb" -s "$serial" shell am broadcast -a com.android.systemui.demo -e command notifications -e visible false >/dev/null

  local defines=(--dart-define=PH_DEMO=true --dart-define=PH_NO_SPLASH=true)
  [ -f "$APP/dart_defines/store.json" ] && defines+=(--dart-define-from-file=dart_defines/store.json)
  rm -rf "${APP:?}/build/screenshots"
  (cd "$APP" && flutter drive --driver=test_driver/integration_test.dart --target=integration_test/demo_flow_test.dart -d "$serial" "${defines[@]}")
  "$adb" -s "$serial" shell am broadcast -a com.android.systemui.demo -e command exit >/dev/null || true
  mkdir -p "$SHOTS"
  find "${SHOTS:?}" -maxdepth 1 -name '*.png' -type f -delete
  cp "$APP"/build/screenshots/*.png "$SHOTS"/
  echo "$(find "$SHOTS" -maxdepth 1 -name '*.png' | wc -l) screenshots in $SHOTS"
}

[ "$do_images" = 1 ] && images
[ "$do_shots" = 1 ] && shots
exit 0
