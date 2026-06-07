# Postmortem: boot-dependent white fog ("white void")

Symptom: on a fraction of app launches, fogged areas rendered saturated white
instead of the map's fog color — most visibly on foggy maps (hm_borg1, hm_dn2)
as a white mass where the black-fogged "void" should be, as a whole-screen
white wash when loading into a map, and behind death/scoreboard views. With
bloom enabled the bloom chain spread the white across the entire frame. A bad
launch stayed bad for the whole session; the next launch could be fine.

## Root cause

`vk_compat.c` defines `float Q_atof( const char *str )` for the Quake3e-derived
Vulkan renderer, but no header declared it. Under C's implicit-declaration rule
every call site in renderervk compiled against an assumed `int Q_atof()`:

- the definition returns its result in the float register (`s0`),
- callers read the integer register (`w0`), i.e. unrelated leftover data.

Every numeric token the renderer parses from shader scripts goes through
`Q_atof` — `fogParms`, wave amplitudes, `tcMod` rates, `deformVertexes`
parameters. All of them received register garbage that varied from launch to
launch but was stable within one session (the values are parsed once at load).

For `textures/borg/fog_black` (`fogparms ( 0 0 0 ) 256`), the parsed fog color
came back around 8.4e6 instead of 0. The collapsed-fog fragment path
`mix( base, fog * fogColor, fog.a )` then saturated toward white with distance.
Launches where the garbage happened to be small or negative looked normal,
which made the bug appear device- or driver-dependent. It is neither: the same
miscompiled read happens on every ARM64/ARM32 build.

The build silenced the one diagnostic that names this bug —
`-Wno-implicit-function-declaration` in `app/jni/src/CMakeLists.txt`.

## Fix

- Declare `Q_atof`, `Com_GenerateHashValue`, `crc32_buffer` (vk_compat.c
  exports) and `R_RandomOn` in `renderervk/tr_local.h`. The header already
  declared the pointer-returning compat functions for exactly this reason;
  the float-returning one had been missed.
- Replace `-Wno-implicit-function-declaration` with
  `-Werror=implicit-function-declaration` so this class of bug fails the build.

## How it was isolated

GPU-side theories (tile-GPU writeback elimination, `DONT_CARE` load ops,
swapchain content reuse) all failed against the evidence. The steps that
actually converged:

1. The engine's own `screenshot` command reads the offscreen color image
   *before* the gamma/present pass — white in those captures placed the fault
   in rendered content, not the present chain.
2. The captures showed world geometry visible through a distance-graded white
   wash: fog blending toward white, not undefined memory.
3. Logging the fog uniform at the write site showed the CPU itself feeding
   ~8.4e6 per channel; logging up the chain (`fog_t::color` at map load, then
   `fogParms` at shader parse) walked it back to `Q_atof`.
4. The compiler confirmed it: with the print added, clang warned
   "format specifies 'double' but the argument has type 'int'" for a
   `Q_atof(...)` argument.

While chasing the wrong theories the render-pass code still picked up real
hardening (kept): swapchain/resolve-target load ops changed from `DONT_CARE`
to `CLEAR`, `initSwapchainLayout = UNDEFINED` (removes pre-acquire layout
transitions that violate WSI ownership), always passing all three clear values
(the screenmap pass is multisampled regardless of `r_ext_multisample`),
acquire `VK_TIMEOUT`/`VK_NOT_READY` handling, a swapchain image-count bounds
check, wireframe-pipeline fallback when `fillModeNonSolid` is unsupported, and
a `pVertexAttributeDescriptions` copy-paste fix in the post-process pipelines.

## Debug tooling notes (Android, kept for future work)

- Khronos validation layer on a device build: set `debuggable true` (temp) in
  app/build.gradle, copy libVkLayer_khronos_validation.so into
  app/src/main/jniLibs/<abi>/, then:
    adb shell settings put global enable_gpu_debug_layers 1
    adb shell settings put global gpu_debug_app com.voyager.ef
    adb shell settings put global gpu_debug_layers VK_LAYER_KHRONOS_validation
    adb shell setprop debug.hwui.renderer skiagl
  Sync validation: setprop debug.vulkan.khronos_validation.enables
  VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT
  Revert all of it afterwards.
- Boot-loop A/B harness: push a temporary autoexec.cfg (cvar overrides +
  `devmap` + `screenshot`), cycle force-stop/start over adb, pull
  baseEF/screenshots/ and compare pixel statistics per boot.
- The engine screenshot path reads `vk.color_image` (pre-gamma) when r_fbo 1,
  the swapchain image when r_fbo 0 — useful to bisect rendered-content bugs
  from present-path bugs.
