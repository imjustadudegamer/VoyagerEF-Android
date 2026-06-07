# Bloom white-screen bug — investigation notes

OPEN BUG (2026-06-07). Boot-dependent solid-white rendering of the 3D view with
`r_bloom 1`, observed on a Mali-G78 device. HUD/2D and the first-person weapon
render correctly on top; the world area is pure 255-white. Manifests visibly on
"empty" views — loading screens, spawn intro, death/scoreboard, looking into the
void on foggy maps (hm_borg1 "Assimilation", hm_dn2) — but on a bad boot the whole
session is affected; on a good boot the session is clean. Roughly every other boot.

`r_bloom 0` (Video options) avoids it; that is the user-facing workaround.

## Established facts (each verified, in order)

1. Whole-world white behind correctly-drawn weapon + HUD (screenshots, pixel
   sample = exactly 255,255,255). Normal gameplay frames in corridors are fine
   on the same boot.
2. NOT the fog being bright: hm_borg1's fog is `textures/borg/fog_black`,
   fogparms ( 0 0 0 ).
3. Frame anatomy (backend instrumentation): on scoreboard/death frames the world
   scene draws, `vk_bloom()` runs at the 3D->2D transition leaving the post-bloom
   pass open, then cgame draws FOUR more 3D scenes (RDF_NOWORLDMODEL — the 3D
   player-head icons) inside the post-bloom pass.
4. Two real validity bugs found there and FIXED (kept, they were genuine UB):
   - POST_BLOOM pipeline variants had depth/stencil enabled while the post-bloom
     pass has no depth attachment (vk.c create_pipeline now forces them off).
   - vk_clear_depth() could record a depth-aspect vkCmdClearAttachments inside
     the depthless post-bloom pass (now guarded).
   White persisted after both.
5. All non-transient color attachments are now cleared at creation
   (vk_alloc_attachments init-clear; also kept — correct hygiene). White persisted.
6. Khronos validation layer (1.4.350, packed into a debuggable APK,
   HWUI forced to skiagl to avoid a layer/HWUI abort): core validation CLEAN
   during white frames. Only init-time noise plus 20x wireframe pipelines created
   without fillModeNonSolid (r_showtris debug pipelines — minor, fix someday).
7. Synchronization validation (enables=VK_VALIDATION_FEATURE_ENABLE_
   SYNCHRONIZATION_VALIDATION_EXT, confirmed acknowledged by the layer):
   ZERO SYNC-HAZARD through load -> bot match -> death. API-valid AND sync-clean.
8. Attachment tint test: init-clear colored per class (color image RED, bloom
   extract GREEN, blur chain BLUE, screenmap MAGENTA, other YELLOW) — the bad
   area was STILL WHITE, not any tint. => The white does NOT come from sampling
   never-written attachment memory.

## Surviving hypotheses (untested)

- Host-side uninitialized memory feeding the bloom path deterministically per
  boot: spec constants / push constants / uniform staging for the extract,
  blur, or blend pipelines (NaN or huge float -> white output on Mali).
  Audit `vk_create_post_process_pipeline`, `vk_create_blur_pipeline`,
  `vk_bloom()` descriptor/uniform inputs, and anything `r_bloom_*`-derived
  computed before cvar init or after vid_restart re-creation.
- Mali driver bug in the bloom pass sequence (extract -> 6x blur -> additive
  blend) — e.g. mishandled storeOp/loadOp chain on r8g8b8a8 (vk.bloom_format)
  at odd mip sizes. Compare 1920x1080 vs 2400x1080 devices.
- NaN propagation: if any blur weight/texel is NaN, additive blend clamps to
  white on some GPUs. The earlier "threshold 1.0 + intensity 0 made it go away"
  observation supports a multiplied-garbage theory but was taken on a single
  boot and may have been boot-luck — re-test across multiple boots.

## Recommended next steps (in order)

1. RenderDoc capture of a white frame (RenderDoc is already installed on the
   Windows side; app must be debuggable=true temporarily — see build.gradle
   release block). Inspect the bloom extract output and blend inputs directly;
   this ends the guessing.
2. Host uninit audit of the bloom pipeline creation parameters (above).
3. Multi-boot retest of r_bloom_threshold/intensity sensitivity.
4. If a Mali workaround is needed and root cause stays elusive: skip vk_bloom()
   when the current frame never wrote the color attachment, or gate bloom off
   by default on the affected driver as a last resort (vk.qcomClearBug-style
   gate, documented as such).

## Debug tooling recipes proven this session

- Validation layer on a release-signed build: set `debuggable true` (TEMP) in
  app/build.gradle release block; copy libVkLayer_khronos_validation.so into
  app/src/main/jniLibs/arm64-v8a/ (loader finds it in the APK); then
    adb shell settings put global enable_gpu_debug_layers 1
    adb shell settings put global gpu_debug_app com.voyager.ef
    adb shell settings put global gpu_debug_layers VK_LAYER_KHRONOS_validation
    adb shell setprop debug.hwui.renderer skiagl   # or HWUI+layer aborts
  Sync validation: setprop debug.vulkan.khronos_validation.enables
  VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT
  Revert ALL of this after use (settings delete global ..., remove jniLibs,
  remove debuggable).
- Backend frame-anatomy logging: ri.Printf markers in RB_DrawSurfs /
  vk_bloom / vk_begin_main_render_pass; read with
  adb logcat -d VoyagerEF:I '*:S'.
- Attachment blame-by-tint: clear each attachment class to a distinct color in
  vk_alloc_attachments' init-clear and look at what leaks on screen.
