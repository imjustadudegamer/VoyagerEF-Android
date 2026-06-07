#!/usr/bin/env bash
# Full build pipeline: sync canonical engine sources -> rebuild ui.qvm ->
# refresh APK assets -> gradle debug build -> copy APK artifact.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"          # android-port/
ROOT="$(dirname "$HERE")"                      # VoyagerNX_Android/
ENGINE_SRC="$ROOT/lilium-voyager-master/code"
ENGINE_DST="$HERE/EFAndroid/app/jni/efcode"
ASSETS="$HERE/EFAndroid/app/src/main/assets/baseEF"

echo "== [1/5] syncing engine sources -> jni/efcode =="
if [ -d "$ENGINE_SRC" ]; then
  rsync -a --delete "$ENGINE_SRC/" "$ENGINE_DST/"
  diff -rq "$ENGINE_SRC" "$ENGINE_DST"
  echo "   engine trees identical."
else
  echo "   no engine tree at $ENGINE_SRC — building jni/efcode as checked out."
fi

echo "== [2/5] building ui.qvm =="
if [ -d "$ROOT/stvoy/Code-DM/ui" ]; then
  "$HERE/build-ui-qvm.sh"
else
  echo "   UI toolchain not present — keeping the prebuilt assets/baseEF/vm/ui.qvm."
fi

echo "== [3/5] refreshing APK assets =="
mkdir -p "$ASSETS/vm"
[ -f "$HERE/ui.qvm" ] && cp -v "$HERE/ui.qvm" "$ASSETS/vm/ui.qvm"
cp -v "$HERE/android_defaults.cfg" "$ASSETS/android_defaults.cfg"
cp -v "$HERE/autoexec.cfg"         "$ASSETS/autoexec.cfg"

echo "== [4/5] gradle assembleDebug =="
cd "$HERE/EFAndroid"
JAVA_HOME="${JAVA_HOME:-$HOME/jdk21}" ./gradlew :app:assembleDebug

echo "== [5/5] copying APK artifact =="
cp -v "$HERE/EFAndroid/app/build/outputs/apk/debug/app-debug.apk" \
      "$HERE/VoyagerEF-debug.apk"

echo "DONE: $HERE/VoyagerEF-debug.apk"
