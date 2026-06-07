# Voyager Elite Force for Android

A native Android port of *Star Trek: Voyager — Elite Force* **Holomatch** (the
multiplayer game, 2000), inspired by and building on
[VoyagerNX](https://github.com/faithvoid/VoyagerNX), faithvoid's Nintendo Switch port —
VoyagerNX proved the ARM + console-controls path this project started from. The engine
base is [lilium-voyager](https://github.com/clover-moe/lilium-voyager) with the Vulkan
renderer from [Quake3e](https://github.com/ec-/Quake3e). Online play and offline
matches against bots, touch controls, full gamepad support.

No game data is included. You need your own copy of the retail game
(GOG release, original CD + patches, or an existing PC install).

## Features

- Vulkan renderer (Quake3e renderervk, adapted to the Elite Force engine) — see
  [VULKAN_RENDERER.md](VULKAN_RENDERER.md). OpenGL ES (renderergl2) remains available
  as a build-time fallback.
- ARM JIT (`vm_armv7l`) for the game QVMs.
- Touch controls: virtual stick, look area, and an LCARS-styled button overlay that
  auto-hides while a gamepad is in use.
- Gamepad: SDL GameController mapping, dual-analog defaults, rebindable in the
  Controls menu, proper analog movement scaling.
- Widescreen: the 2D menu can fill any aspect (`cl_flexibleDisplay`), or keep the
  original 4:3; `r_mode -2` renders at native resolution.
- In-app game-data import: if the game data is missing at launch, the app lets you pick
  your `pak*.pk3` files with the system file picker and copies them into place. No
  storage permission needed at any target SDK.
- Single-column video menu rebuilt for phone screens, first-boot player-name prompt,
  soft-keyboard support.

## Requirements

- Android 7.0+ (API 24) with Vulkan support — the APK declares Vulkan as a required
  feature. (An OpenGL ES build is possible from source with `-DEF_RENDERER=gl2`.)
- A device that runs 32-bit ARM binaries. **The APK is 32-bit (`armeabi-v7a`) only —
  64-bit is not enabled by default.** The QVM JIT is 32-bit ARM only, so an arm64
  build would fall back to the much slower bytecode interpreter; a proper arm64 build
  is planned once the aarch64 JIT is ported. Recent devices that dropped 32-bit
  support entirely cannot run this APK yet. If you want to try the interpreter
  anyway, add `'arm64-v8a'` to `abiFilters` in `EFAndroid/app/build.gradle` and
  build from source.
- Retail Elite Force data: `pak0.pk3` (541 MB) plus the official patch paks
  `pak1.pk3`–`pak3.pk3` from `BaseEF/` of a PC installation.

## Install

1. Copy your four `pak*.pk3` files onto the phone (anywhere — Downloads is fine).
2. Install the APK and launch it.
3. When asked, pick the four pak files. They are copied into the game's data
   directory and the game starts. That's the whole setup; next launches go straight
   into the game.

For development there's `./deploy-to-phone.sh`, which installs the APK, pushes the
paks over adb (point `EF_PAKS` at them) and launches with logcat attached. The manual
push target is `/sdcard/Android/obb/com.voyager.ef/baseEF/` (lowercase `baseEF`).

## Build

```sh
cd EFAndroid
./gradlew :app:assembleDebug    # output: app/build/outputs/apk/debug/app-debug.apk
```

Needs: Android SDK platform 35, NDK 25.1.8937393, CMake 3.31.5, JDK 21.
First run downloads Gradle 8.9 / AGP 8.7.2.

- Engine sources compiled into the APK live in `EFAndroid/app/jni/efcode/`
  (lilium-voyager plus the Android/Vulkan port layer; GPLv2, see
  [COPYING.txt](COPYING.txt)).
- `./build-all.sh` is the full pipeline (engine sync → ui.qvm → assets → APK).
- `./build-native.sh [abi]` is a fast compile check of `libmain.so` without packaging.
- Renderer selection: `-DEF_RENDERER=vulkan` (default in the Gradle build) or `gl2`.

### ui.qvm

The UI module is rebuilt from the Elite Force GDK sources with the Android additions
(video menu, name prompt, bind capture). The prebuilt `ui.qvm` ships in
`EFAndroid/app/src/main/assets/baseEF/vm/` and is what the APK uses; rebuilding it
(`build-ui-qvm.sh`) requires the GDK `Code-DM` tree and Raven's lcc/q3asm toolchain,
which are not part of this repo. String-table compatibility with the retail data is
documented in [UI_STRING_ALIGNMENT.md](UI_STRING_ALIGNMENT.md).

Port-specific runtime assets (touch overlay art, Android config) ship inside
`zpak-android.pk3` so they survive the engine's pure-filesystem checks; loose files
under `baseEF/` are only reliable before a map loads.

## Known issues / roadmap

- Pipeline prewarm after map load is not wired up yet, so the first appearance of an
  effect can hitch briefly.
- Some beam effects (e.g. the arc-welder weapon beam) do not render yet.
- Ogg/Opus/MP3 decoding and curl downloads are not compiled in yet. This doesn't
  affect the retail game (all stock audio is WAV) — only community content that ships
  compressed audio, and in-game http downloads. The library sources are already in the
  tree; they just need to be wired into the Android build.
- 64-bit (arm64) is not built by default — see Requirements.
- Render-thread split (keeping input and sim at full rate during backend stalls) is
  planned.

## Multiplayer

IPv4 networking is enabled (`INTERNET` is the only permission). The original Raven
master server is gone; lilium's community master (`efmaster.tjps.eu`) is configured as
a fallback.

## License & credits

Engine and port code are GPLv2 ([COPYING.txt](COPYING.txt)). *Star Trek* and related
marks belong to Paramount/CBS; this is a non-commercial fan port and includes no game
assets. Full attribution in [CREDITS.md](CREDITS.md).
