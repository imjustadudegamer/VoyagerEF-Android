# Vulkan + Multithreaded Renderer Port — Elite Force / lilium-voyager on Android

## Why (root cause, confirmed by profiling)
Panning stutter = renderergl2's GL driver re-validating/compiling pipeline state mid-draw as new
surface/shader combos stream into the frustum on Mali (tile-based deferred). Confirmed NOT: fill-rate
(half-res no help), VM (JIT'd), first-use shader compile (prewarm + 5000 frames no help), thermal,
flares, explicit syncs. Every smooth Android Quake3 port avoids renderergl2. Vulkan fixes the ROOT
cause: pipeline state is baked into explicit VkPipeline objects created up-front (no mid-draw
re-validation). Single-threaded engine also means an 800ms backend stall freezes input+sim+render
together → a render thread keeps input/sim at 60fps during any stall.

## Source of the renderer
Quake3e (ec-/Quake3e) `code/renderervk/` — cloned to `quake3e-ref/` at the repo root.
Mature Vulkan Q3 renderer (vk.c ~8000 lines + vk_vbo.c + vk_flares.c + vk.h ~9.5k vk-specific;
the tr_*.c are shared renderer logic close to ioq3). SDL2-Vulkan based → Android-capable.
GUNNM-VR proved renderervk runs fast on Android Mali/Adreno. Pipelines for the MAIN pass are created
EAGERLY at map load (tr_shader.c:3592 use=qtrue) → world panning won't stutter. Mirror/portal/
secondary-pass pipelines are lazy → close with a prewarm loop (see Phase 2).

## Integration strategy: Approach B (keep EF engine intact, swap only the renderer module)
- KEEP lilium's engine (client/server/VM syscalls) and lilium's renderercommon/tr_public.h
  (REF_API_VERSION 9, USE_FLEXIBLE_DISPLAY) UNCHANGED → cgame/ui/qagame QVMs keep working.
- Add renderervk as a NEW renderer dir alongside renderergl2 (don't delete gl2 — keep a working
  fallback, switch via a CMake flag EF_RENDERER=vulkan|gl2).
- renderervk's GetRefAPI fills LILIUM's refexport_t (adapt Quake3e's GetRefAPI to lilium's struct).
- renderervk's internal `ri` (refimport) calls must all resolve against LILIUM's refimport; stub/adapt
  the Quake3e-only ones (Microseconds, Cvar_SetGroup/Group APIs, JPEG helpers, CL_* extras).
- Vulkan surface: renderer is statically linked, so call SDL_Vulkan_* DIRECTLY from the renderer's
  vk init (replace Quake3e's ri.VK_CreateSurface / ri.VK_GetInstanceProcAddr with SDL_Vulkan_CreateSurface
  / SDL_Vulkan_GetVkGetInstanceProcAddr). Window must be created with SDL_WINDOW_VULKAN (not _OPENGL).

## EF-specific renderer features to carry into renderervk (lilium has them in gl2; port to vk's tr_*.c)
(from tr_types.h / tr_surface.c / tr_light.c / tr_shade.c / tr_shader.c / tr_glsl shaders)
- refEntityType primitives: RT_ORIENTEDSPRITE, RT_ALPHAVERTPOLY, RT_LINE, RT_ORIENTEDLINE, RT_LINE2,
  RT_BEZIER, RT_CYLINDER, RT_ELECTRICITY (tr_surface.c RB_Surface* + the refEntity union data).
- renderfx: RF_FULLBRIGHT (tr_light.c fixed ambient), RF_FORCE_ENT_ALPHA (tr_shade.c stage alpha override).
- RE_RegisterShader3D (LIGHTMAP_NONE) → refexport v9 has it.
- EF env-map shader math (.xy reflect, generic_vp), r_origfastsky color, NO deform-text (skip DEFORM_TEXT).
- glconfig_t EF layout (extensions_string 2*MAX_STRING_CHARS, textureFilterAnisotropicAvailable) — ABI.
- Models: MD3 + MDR (skeletal) + IQM — Quake3e ALREADY supports all three. BSP 46 same.
- Touch UI draws via re.DrawStretchPic/RegisterShaderNoMip/charSetShader → works once RE_StretchPic +
  2D ortho (RB_SetGL2D / Mat4Ortho) are correct.

## Android Vulkan setup (SDL2 2.30.x)
- SDL_Vulkan_LoadLibrary(NULL) → SDL_Vulkan_GetVkGetInstanceProcAddr() → resolve all qvk* (NO -lvulkan).
- Window flag SDL_WINDOW_VULKAN. SDL_Vulkan_GetInstanceExtensions → VK_KHR_surface + VK_KHR_android_surface.
- minSdk 24 (Vulkan 1.0); manifest <uses-feature android.hardware.vulkan.version required=false> (keep gl2 fallback).
- Present mode FIFO (universal, smooth, power-efficient). Lock landscape (already done) to dodge pre-rotation;
  else preTransform==currentTransform + MVP rotate.
- Swapchain recreate on VK_SUBOPTIMAL/OUT_OF_DATE; DEFER recreate on SURFACE_LOST until resume (ANativeWindow NULL crash).
- Keep Quake3e's transient/LAZILY_ALLOCATED depth + DONT_CARE store ops (Mali tile bandwidth win).

## PHASES
- **Phase 0 (done):** research + clone. Working gl2+JIT build preserved as fallback.
- **Phase 1: Vulkan renderer builds + boots to a frame.** Bring renderervk into tree; SDL Vulkan surface;
  GetRefAPI→lilium refexport; reconcile refimport; SPIR-V shaders (precompiled, embedded); CMake to compile
  renderervk + link path; manifest/minSdk. Goal: menu + a map render correctly on device.
- **Phase 2: Pipeline prewarm (the stutter fix).** After map+media load, vk_gen_pipeline over ALL
  vk.pipelines_count × enabled render passes (~15 lines) so no mid-game vkCreateGraphicsPipelines.
  + optional VkPipelineCache disk serialize (UUID-validated) to shorten load.
- **Phase 3: Multithreaded render thread.** id Tech 3 already splits frontend (R_RenderView → renderCommandList)
  / backend (RB_ExecuteRenderCommands). Restore backEndData[2]+tr.smpFrame ping-pong (or 3-deep to match
  Vulkan frames-in-flight); run RB_ExecuteRenderCommands on an SDL_Thread; handoff via condvar/semaphore +
  per-frame VkFence. Vulkan removes the GL thread-affine-context problem that killed the old SMP. Snapshot
  backend cvars per-frame; gate registration/readbacks to render-thread-idle; keep input on main thread.

## Key references
- Quake3e renderervk: github.com/ec-/Quake3e/tree/master/code/renderervk ; vk.c, sdl/sdl_glimp.c (Vulkan path)
- Pipeline prewarm: vk_find_pipeline_ext (vk.c:6599), vk_gen_pipeline (6586), vk_alloc_pipeline (6567),
  create_pipeline (5604), pipeline cache (4324). MAX_VK_PIPELINES 2304. ARM: create at load, serialize cache.
- vkQuake3 (ioq3+Vulkan, Kenny lineage): github.com/suijingfeng/vkQuake3
- Q3E Android Vulkan framework (Quake2 ref_vk, Doom3BFG on Android): github.com/glKarin/com.n0n3m4.diii4a
- GUNNM-VR (Quake3e Vulkan on Android, proof): github.com/GUNNM-VR/Quake-III-Arena-VR-Edition
- Android pre-rotation: developer.android.com/games/optimize/vulkan-prerotation
- SMP/render-thread: id Q3 tr_cmds.c backEndData[smpFrame]; Sanglard quake3/renderer.php + doom3_bfg/threading.php
