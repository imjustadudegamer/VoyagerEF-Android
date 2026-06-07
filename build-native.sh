#!/usr/bin/env bash
# Compile-check helper: fast native-only build of libmain.so (no APK).
# For iterating on engine C code only — gradle (EFAndroid/gradlew
# :app:assembleDebug) is the real build and what produces the APK.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

SDK="${ANDROID_SDK_ROOT:-$HOME/Android/sdk}"
NDK="$SDK/ndk/25.1.8937393"

# Prefer the cmake version gradle pins; fall back to any installed cmake.
CMAKE_BIN="$SDK/cmake/3.31.5/bin"
if [ ! -x "$CMAKE_BIN/cmake" ]; then
  for d in "$SDK"/cmake/*/bin; do
    [ -x "$d/cmake" ] && CMAKE_BIN="$d" && break
  done
fi
CMAKE="$CMAKE_BIN/cmake"
NINJA="$CMAKE_BIN/ninja"
[ -x "$CMAKE" ] || { echo "ERROR: no cmake under $SDK/cmake — install one via sdkmanager"; exit 1; }
[ -d "$NDK" ]   || { echo "ERROR: NDK 25.1.8937393 not found at $NDK"; exit 1; }

ABI="${1:-armeabi-v7a}"
BUILD="$HERE/build-$ABI"

# Same cmake arguments gradle passes (app/build.gradle defaultConfig).
"$CMAKE" -S "$HERE/EFAndroid/app/jni" -B "$BUILD" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" -DANDROID_PLATFORM=android-24 \
  -DANDROID_STL=c++_static -DEF_RENDERER=vulkan

"$NINJA" -C "$BUILD" main
echo "built: $BUILD/src/libmain.so"
file "$BUILD/src/libmain.so"
