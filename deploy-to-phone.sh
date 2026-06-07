#!/usr/bin/env bash
# One-shot: install the EF debug APK on a connected phone, push the retail
# game data into the OBB dir, launch, and tail the log.
# Run after plugging in a phone with USB debugging on.
#
# Set EF_PAKS to the directory holding the retail pak0-3.pk3
# (e.g. an installed copy's BaseEF folder).
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
APK="$HERE/EFAndroid/app/build/outputs/apk/debug/app-debug.apk"
PKG="com.voyager.ef"
DEST="/sdcard/Android/obb/$PKG/baseEF"   # lowercase baseEF (Android is case-sensitive)
ADB="${ADB:-adb}"
DATA_SRC="${EF_PAKS:?Set EF_PAKS to a directory containing pak0-3.pk3}"

[ -f "$DATA_SRC/pak0.pk3" ] || { echo "ERROR: $DATA_SRC/pak0.pk3 not found"; exit 1; }
[ -f "$APK" ] || { echo "ERROR: $APK not found — build it first (gradlew :app:assembleDebug)"; exit 1; }

# Stock data set: retail base + official patches. pak0 has the QVMs + default.cfg.
# (Community map/model paks are optional — add later if you want them.)
PAKS=(pak0.pk3 pak1.pk3 pak2.pk3 pak3.pk3)

echo "== checking device =="
"$ADB" wait-for-device
"$ADB" devices -l | grep -qw device || { echo "No device in 'device' state. Authorize USB debugging on the phone."; exit 1; }

echo "== installing APK =="
"$ADB" install -r "$APK"

echo "== pushing game data to OBB dir (pak0 is 541MB, be patient) =="
"$ADB" shell mkdir -p "$DEST"
for p in "${PAKS[@]}"; do
  if "$ADB" shell ls "$DEST/$p" >/dev/null 2>&1; then
    echo "  -> $p already on device, skipping"
    continue
  fi
  echo "  -> $p"
  "$ADB" push "$DATA_SRC/$p" "$DEST/"
done

echo "== launching =="
"$ADB" shell am start -n "$PKG/com.voyager.ef.ImportActivity"

echo "== logcat (Ctrl-C to stop) =="
"$ADB" logcat -c
"$ADB" logcat SDL:V libmain:V VoyagerEF:V DEBUG:V AndroidRuntime:E "*:S"
