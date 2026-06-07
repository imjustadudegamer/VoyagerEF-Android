# Elite Force on Android — build & install

Status: **the engine compiles, links, and packages into an installable arm64 APK that boots via
SDL2/SDLActivity, and boots + plays on-device.** What remains for comfortable gameplay is a touch
controls overlay. See `../ANDROID_PLAN.md`.

## What is built

- `VoyagerEF-android-arm64-debug.apk` (~4 MB) — package `com.voyager.ef`, launches
  `org.libsdl.app.SDLActivity` → `libmain.so` (`SDL_main`). Contains `lib/arm64-v8a/{libSDL2.so,libmain.so}`.
- Engine: **lilium-voyager** sources (chosen over VoyagerNX because lilium has the working
  OpenGL **ES** context path; VoyagerNX's Switch glimp uses Mesa *desktop* GL). Single binary,
  interpreted VM (`NO_VM_COMPILED`), `renderergl2` statically linked, SDL audio (OpenAL optional
  via dlopen), no curl/ogg/opus/mp3 in this first cut.

### Android-specific source changes (all guarded by `#ifdef __ANDROID__`)
- `code/sys/sys_unix.c` `Sys_DefaultHomePath()` → `SDL_AndroidGetExternalStoragePath()`.
- `code/sys/sys_main.c` `DEFAULT_BASEDIR` → `SDL_AndroidGetExternalStoragePath()`.
- `code/sdl/sdl_glimp.c` `r_preferOpenGLES` default → `1` (request a GLES context).
- `sys_main.c`'s `main()` is renamed to `SDL_main` via a per-file CMake define.

## Layout

```
android-port/
  SDL2-2.30.9/            SDL2 source (harness)
  EFAndroid/              Gradle project (the APK)
    app/jni/SDL           SDL2 2.30.9 sources
    app/jni/efcode        engine sources — plain directory copy of
                          ../../lilium-voyager-master/code, kept in sync by
                          android-port/build-all.sh (rsync)
    app/jni/src/CMakeLists.txt   the engine build (libmain.so)
  build-arm64/            standalone CMake build output (fast iteration)
  VoyagerEF-android-arm64-debug.apk
```

Note: `app/jni/efcode` is **not** a symlink. Edit engine code in `lilium-voyager-master/code`
and let `android-port/build-all.sh` rsync it into the Gradle tree.

## Rebuild the APK

```sh
cd android-port/EFAndroid
./gradlew :app:assembleDebug          # output: app/build/outputs/apk/debug/app-debug.apk
```
Requires: Android SDK (`$ANDROID_SDK_ROOT`) with platform `android-35`, NDK `25.1.8937393`,
JDK 21, CMake 3.31.5. First run downloads Gradle 8.9 + AGP 8.7.2.

## Fast native-only rebuild (just the .so, no APK) — for iterating on engine code

```sh
cd android-port
./build-native.sh        # configures + builds build-arm64/src/libmain.so
```

## Install on a phone

```sh
adb install -r android-port/VoyagerEF-android-arm64-debug.apk
adb logcat -s SDL libmain VoyagerEF *:E     # watch it boot
```
(arm64 device, Android 7.0+/API 24+.)

## Game data

Retail data must come from a retail Elite Force installation (e.g. a cMod install):
stock `pak0.pk3` (541M, contains the QVMs + default.cfg) + official patches `pak1/2/3.pk3`,
plus optional community map/model paks. Validated by building lilium's headless
dedicated server and loading `ctf_voy1` from this data: `qagame.qvm` loads and runs,
`com_gamename=EliteForce`, map + AAS load clean. The engine+data+QVM pipeline is proven on
desktop.

On device the data lives at (lowercase `baseEF` — Android is case-sensitive):
**`/sdcard/Android/obb/com.voyager.ef/baseEF/*.pk3`**

Data import happens **in-app**: on first launch the app opens a file picker to import the
`pak*.pk3` files from a retail installation. Alternatively, push them with adb:

### One-shot deploy (when an arm64 phone is connected with USB debugging)
```sh
./deploy-to-phone.sh      # installs APK, pushes pak0-3, launches, tails logcat
```
This pushes the stock `pak0-pak3` set only; community paks are optional extras that can be
pushed later.
(`pak3.pk3` flags a harmless zero-byte `env/` directory entry under `unzip -t` — all real files are intact.)

## Progress log
- **Boots + plays on-device** (tested: Pixel 6a, Android 16, Mali-G78): menu + in-game 3D,
  GLES ES 3.2, AAudio, touch-as-mouse. Screenshots `screenshot-*.png`.
- **Storage:** `/sdcard/Android/obb/com.voyager.ef/baseEF/`; game data is imported in-app via
  the file picker on first launch. The only manifest permission is `INTERNET`.
- **Networking:** `INTERNET` permission (IPv4 sockets open). Master server: the default
  `master.stef1.ravensoft.com` is long dead; lilium ships `efmaster.tjps.eu` as sv_master2 — a live
  community master + cMod-data specifics still need confirming (see CREDITS.md, cMod).
- **16 KB page compatibility:** `-Wl,-z,max-page-size=16384` → both .so segment-aligned to 0x4000.
- **Landscape:** `SDL_HINT_ORIENTATIONS` (manifest orientation alone is overridden by SDL).
- **Widescreen fill:** `USE_FLEXIBLE_DISPLAY` compiled in; `cl_flexibleDisplay 4+` stretches the 2D
  menu to fill (modes ≤3 keep EF's authentic 4:3). `r_mode -2` = native res on any device.
- **Gamepad:** `in_joystick`/`in_joystickUseAnalog` default on for Android; SDL auto-maps Android
  pads to `PAD0_*`; binds + sensitivity in `autoexec.cfg`. Touch-as-mouse auto-disables when a
  controller connects.
- **Icon:** real EF logo (`menu/endcredits/ef_logo.tga`) → launcher icon. Name "Voyager EF".
- **Tuning in `autoexec.cfg`:** `r_depthPrepass 0` (mobile black-triangle artifacts),
  `r_mapOverBrightBits 1` (lighting was too bright).

## Next steps
- Touch controls overlay (SDL gives basic touch→mouse only; an on-screen stick/buttons HUD is TODO).
- armeabi-v7a (32-bit) ABI in addition to arm64.
- Re-enable ogg/opus/mp3 + curl.
- Continue validating the `renderergl2` GLES path across GPUs.
