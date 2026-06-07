# The Vulkan renderer

This port renders through `renderervk`, the Vulkan renderer from
[Quake3e](https://github.com/ec-/Quake3e), adapted to the Elite Force engine. It is the
default build (`-DEF_RENDERER=vulkan`); the OpenGL ES path (`renderergl2`) is kept as a
build-time fallback (`-DEF_RENDERER=gl2`).

## Why not GL ES

Profiling the GL build on a tile-based mobile GPU showed panning stutter caused by
the driver re-validating and recompiling pipeline state mid-draw as new surface/shader
combinations stream into view. It was not fill-rate (half resolution didn't help), not
the VM (JIT'd), not first-use shader compile (prewarming didn't help), and not thermal.

Vulkan removes the root cause: pipeline state is baked into explicit `VkPipeline`
objects created up front, so nothing is re-validated mid-draw. Quake3e creates the
main-pass pipelines eagerly at map load.

## Integration approach

The engine (client, server, VM syscalls) and the renderer ABI
(`renderercommon/tr_public.h`, `REF_API_VERSION 9` with flexible-display support) stay
unchanged, so the game's cgame/ui/qagame QVMs keep working untouched. `renderervk` was
brought in as an additional renderer directory and statically linked.

The seams, in order of effort:

- **refexport**: Quake3e's `GetRefAPI` was rewritten to fill Elite Force's
  `refexport_t` — Quake3e-only entry points dropped, signatures adapted
  (`RE_Shutdown`, `RE_AddRefEntityToScene`), EF's `RegisterShader3D` added.
- **refimport**: the engine grew the handful of imports renderervk calls
  (`Sys_Microseconds`, JPEG writers, etc.); Quake3e's cvar-group API is stubbed since
  the EF cvar system has no groups. `Cvar_CheckRange` differs in signature and goes
  through a small wrapper.
- **Window/surface**: the renderer talks to SDL directly —
  `SDL_WINDOW_VULKAN`, `SDL_Vulkan_LoadLibrary(NULL)`,
  `SDL_Vulkan_GetVkGetInstanceProcAddr`, `SDL_Vulkan_CreateSurface`. No `-lvulkan`;
  everything is resolved dynamically, so devices without Vulkan can still run the gl2
  build (`android.hardware.vulkan.version` is declared `required=false`).
- **SPIR-V**: shaders are precompiled and embedded; nothing is compiled on device.

## Elite Force renderer features carried over

EF extends the id Tech 3 renderer in ways Quake3e doesn't have, so these were ported
into renderervk from the gl2 renderer:

- The EF entity types: `RT_ORIENTEDSPRITE`, `RT_ALPHAVERTPOLY`, `RT_LINE`,
  `RT_ORIENTEDLINE`, `RT_LINE2`, `RT_BEZIER`, `RT_CYLINDER`, `RT_ELECTRICITY`
  (phaser/beam/effect surfaces and the `refEntity_t` data union that feeds them).
- `RF_FULLBRIGHT` (fixed ambient) and `RF_FORCE_ENT_ALPHA` (forced-blend stage alpha —
  needs a cached blended variant of the stage pipeline, since blend state is baked into
  precompiled Vulkan pipelines).
- `RE_RegisterShader3D`, the `disable` depthfunc, `r_origfastsky`, EF's `glconfig_t`
  layout, and the EF shader text quirks (no `DEFORM_TEXT`).
- MD3/MDR/IQM models and BSP 46 were already supported by Quake3e.

## Android specifics

- Present mode FIFO; landscape locked (avoids pre-rotation handling).
- Swapchain recreate on `VK_SUBOPTIMAL`/`OUT_OF_DATE`; on `SURFACE_LOST` the recreate
  is deferred until resume (the `ANativeWindow` is gone while backgrounded).
- Quake3e's transient/lazily-allocated depth attachments and `DONT_CARE` store ops are
  kept — they save real bandwidth on tilers — except where an attachment is actually
  stored: with bloom on, the multisampled color attachment gets `storeOp=STORE`, so it
  is allocated as a regular device-local image (storing into lazily-allocated memory is
  contradictory, and Adreno corrupts it).

## Correctness fixes found on device (vs upstream Quake3e)

- **Render-pass compatibility for post-bloom pipelines**: upstream creates every
  pipeline's `POST_BLOOM` handle against the MSAA main render pass, then binds it
  inside the single-sample post-bloom pass. That sample-count mismatch is a spec
  violation Mali forgives — Adreno (530 and 740 verified) renders all post-bloom 2D
  as banded garbage and can eventually hang the GPU (`VK_ERROR_DEVICE_LOST`).
  `create_pipeline` now builds `POST_BLOOM` handles against the post-bloom render
  pass at 1 sample.
- **Framebuffer-global external dependencies**: the main pass's external deps guard
  attachment→sampled-read transitions (gamma/bloom sample the offscreen image), so
  `VK_DEPENDENCY_BY_REGION_BIT` was removed — sampled reads aren't framebuffer-local.
- **Draw-based clears on old Adreno**: Qualcomm proprietary drivers below 512.762.12
  race `vkCmdClearAttachments` against draw calls (Google issue 166809097, the same
  workaround ANGLE ships). On those drivers the mid-pass depth/color clears are drawn
  as fullscreen quads instead.

## Pipeline prewarm

Implemented (see `PIPELINE_PREWARM.md` for the full design): after cgame finishes
registering media (`RE_EndRegistration`, loading screen still up),
`vk_prewarm_pipelines()` compiles every registered-but-uncompiled pipeline for the
render passes in use, so no `vkCreateGraphicsPipelines` ever runs mid-frame. The EF
`RF_FORCE_ENT_ALPHA` blended variants are pre-derived at shader registration so the
sweep covers them. Measured: ~440 pipelines in ~130 ms (Adreno 740) / ~370 ms
(Adreno 530), behind the load screen. The sweep also reruns after swapchain restarts.
Still optional: a disk-serialized `VkPipelineCache` to cut load times further.

## Still open

- **Beam rendering**: some `RT_ELECTRICITY`/`RT_LINE` effects (arc-welder beam) don't
  draw yet; under investigation.
- **Render thread**: id Tech 3's frontend/backend split maps cleanly onto a worker
  thread plus per-frame fences, and Vulkan has no thread-affine context. Planned, not
  started.
