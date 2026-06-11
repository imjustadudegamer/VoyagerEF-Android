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
  [VULKAN_RENDERER.md](VULKAN_RENDERER.md). This is the only renderer; the old
  OpenGL ES path has been removed.
- Render thread (`r_smp`, on by default): runs the back-end (Vulkan command
  recording, submit and present) on a dedicated thread, overlapping it with the
  next frame's simulation. Set `r_smp 0` to run single-threaded. See
  [RENDER_THREAD_PLAN.md](RENDER_THREAD_PLAN.md).
- JIT recompilers for the game QVMs on both ABIs: `vm_armv7l` (32-bit, SUSE-derived)
  and `vm_aarch64` (64-bit, Quake3e-derived) — native-speed cgame/qagame/ui
  everywhere, no interpreter fallback. See [AARCH64_JIT_NOTES.md](AARCH64_JIT_NOTES.md).
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
  feature.
- An ARM device. The APK is universal (`armeabi-v7a` + `arm64-v8a`); 64-bit devices
  use the arm64 build with its own QVM JIT, and devices that dropped 32-bit support
  entirely are supported.
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

Everything needed to build is in this repository (engine, SDL2, zlib, libjpeg,
the prebuilt SPIR-V, and the port's bundled assets). No game data is required to
build — only to run.

Prerequisites:

- Android SDK with platform `android-35` and build-tools 35
- NDK `25.1.8937393`
- CMake `3.31.5`
- JDK 21

Point Gradle at your SDK, either with an env var or a `local.properties` file:

```sh
export ANDROID_HOME=/path/to/Android/sdk        # or:
echo "sdk.dir=/path/to/Android/sdk" > EFAndroid/local.properties
```

Then build:

```sh
cd EFAndroid
./gradlew :app:assembleDebug    # output: app/build/outputs/apk/debug/app-debug.apk
```

The first run downloads Gradle 8.9 / AGP 8.7.2. The APK is universal
(`armeabi-v7a` + `arm64-v8a`).

- Engine sources compiled into the APK live in `EFAndroid/app/jni/efcode/`
  (lilium-voyager plus the Android/Vulkan port layer; GPLv2, see
  [COPYING.txt](COPYING.txt)). The renderer is Vulkan-only (`renderervk`).
- `./build-native.sh [abi]` is a fast compile check of `libmain.so` without packaging.

### ui.qvm

The repo does **not** bundle a `ui.qvm`: the UI module is derived from Raven's
Elite Force GDK UI sources, so the engine instead loads the retail `ui.qvm` from
your own `pak2.pk3` at runtime. The game is fully playable that way.

Optionally, a custom `ui.qvm` with the Android additions (single-column video
menu, first-boot name prompt, bind capture) can be built from the GDK `Code-DM`
tree with Raven's lcc/q3asm toolchain (`build-ui-qvm.sh`) and dropped into
`EFAndroid/app/src/main/assets/baseEF/vm/`. String-table compatibility with the
retail data is documented in [UI_STRING_ALIGNMENT.md](UI_STRING_ALIGNMENT.md).

Port-specific runtime assets (the LCARS touch overlay art, Android default
config) ship inside `zpak-android.pk3` so they survive the engine's
pure-filesystem checks; loose files under `baseEF/` are only reliable before a
map loads.

## Known issues / roadmap

- The main menu can only be navigated by touch, or by d-pad up/down on a controller —
  other controller inputs (sticks, face buttons) don't move the menu selection yet.
- If you see corrupted graphics (banding/garbage across the screen), try turning MSAA
  off (Video options, or `r_ext_multisample 0` followed by `vid_restart`) and please
  report your device + GPU driver version.
- The on-screen touch controls are functional but rough; the layout and feel need a
  revamp.
- Ogg/Opus/MP3 decoding and curl downloads are not compiled in yet. This doesn't
  affect the retail game (all stock audio is WAV) — only community content that ships
  compressed audio, and in-game http downloads. The library sources are already in the
  tree; they just need to be wired into the Android build.

## Multiplayer

IPv4 networking is enabled (`INTERNET` is the only permission). The original Raven
master server is gone; lilium's community master (`efmaster.tjps.eu`) is configured as
a fallback.

## License & credits

Engine and port code are GPLv2 ([COPYING.txt](COPYING.txt)). *Star Trek* and related
marks belong to Paramount/CBS; this is a non-commercial fan port and includes no game
assets. Full attribution in [CREDITS.md](CREDITS.md).
