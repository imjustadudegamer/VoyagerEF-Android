# Vulkan Port — exact reconciliation worklist (Phase 1: get renderervk compiling+linking)

renderervk is staged at lilium-voyager-master/code/renderervk/. It includes ../renderercommon/tr_public.h
→ auto-compiles against EF's shared types. gl2 preserved at renderergl2.fallback/ and the build still
uses renderergl2/ (CMake globs it). TESTABLE fallback APK: android-port/VoyagerEF-gl2-jit-TESTABLE.apk.

## A. refexport_t — DON'T add Quake3e extras to the struct. Instead edit renderervk/tr_init.c GetRefAPI:
- DROP these assignments (no slot in EF refexport): AddLinearLightToScene, ThrottleBackend, FinishBloom,
  SetColorMappings, CanMinimize, GetConfig, VertexLighting, SyncRender (tr_init.c ~2079,2094,2096-2101).
- ADAPT signatures to EF's: RE_Shutdown(refShutdownCode_t)→(qboolean destroyWindow);
  RE_AddRefEntityToScene(re, intShaderTime)→(re)  [drop 2nd param or default it].
- ADD EF slots: re.RegisterShader3D = RE_RegisterShader3D (port the fn); ResizeWindow if USE_FLEXIBLE_DISPLAY.
- Use lilium REF_API_VERSION (9 with USE_FLEXIBLE_DISPLAY).

## B. refimport_t — ADD to lilium renderercommon/tr_public.h refimport_t AND fill in client/cl_main.c
   CL_InitRef (assignments block ~line 3412-3464). Renderervk CALLS these; EF lacks them:
- Microseconds (int64_t) → lilium Sys_Microseconds/Com_Microseconds if exists else gettimeofday wrapper.
- FreeAll → no-op or Hunk reset (used in RE_Shutdown tr_init.c:2002).
- Cvar_SetGroup, Cvar_CheckGroup, Cvar_ResetGroup → STUB (no-op / return 0). EF cvar system has no groups;
  cvarGroup_t may not exist → add a typedef enum stub in q_shared.h or guard. Used tr_init/tr_cmds (cosmetic +
  vid_restart-on-group-change; stub = no auto restart, fine).
- Cvar_VariableString, Cvar_VariableStringBuffer → lilium qcommon HAS these; wire directly.
- CL_SaveJPGToBuffer, CL_SaveJPG → lilium has (screenshot/JPG). Wire (check signatures).
- CL_IsMinimized → stub return qfalse (used vk.c:7368/7514/7540/7604, tr_cmds, tr_init).
- Com_RealTime → lilium HAS Com_RealTime. Wire.
- GL_GetProcAddress → stub return NULL (renderervk uses it only for a GL fallback path this port does not take).
- VK_GetInstanceProcAddr, VK_CreateSurface, VKimp_Init, VKimp_Shutdown → IMPLEMENT in sdl/sdl_glimp.c
  via SDL_Vulkan_* (see D). Wire in CL_InitRef.
NOTE signature deltas that are OK via typedef: Printf/Error (printParm_t=int), Hunk/Malloc (size_t vs int),
  Cvar_CheckRange (different sig — ADAPT renderervk callers or add an EF-sig wrapper), Cmd_ExecuteText (enum=int).
  Cvar_CheckRange is the one real mismatch: Quake3e (cv,const char*,const char*,validator) vs EF
  (cv,float,float,qboolean) — renderervk calls it → wrap/translate.

## C. EF renderer features to PORT into renderervk (from renderergl2 — 34 edits). Needed for correct EF
   rendering; SOME needed just to COMPILE (refEntity union field reads). Source = renderergl2/, line refs:
- tr_surface.c: RB_SurfaceSprite use e.data.sprite.radius/rotation (250-256) [COMPILE]; new fns
  RB_SurfaceOrientedSprite(480-525), RB_Line(527-595)+RB_LineNormal(597-606), RB_SurfaceLine(609-635),
  RB_SurfaceOrientedLine(637-657), RB_SurfaceLine2(660-754), RB_SurfaceBezier(757-808),
  RB_SurfaceCylinder(814-976), RB_SurfaceElectricity(979-1043); dispatch cases in RB_SurfaceEntity
  (1756,1774-1795) for the 8 EF reTypes. [phaser/beam fx — needed for HM]
- tr_light.c: RF_FULLBRIGHT (334-353).
- tr_shade.c: RF_FORCE_ENT_ALPHA decls(1031-35)+logic(1060-79)+restore(1467-73).
- tr_shade_calc.c: wrap DeformText() in #ifndef ELITEFORCE (593-595).
- tr_shader.c: depthfunc "disable" (843-847); RE_RegisterShader3D (3729-3759); #define ELITEFORCE in shader (325-26).
- tr_init.c: r_origfastsky cvar decl(75-76)+init(1385-87); textureFilterAnisotropicAvailable(274-75);
  r_ext_compress_textures name(1251-55); r_mapOverBrightBits default 1(1365-69); glconfig size check(1524-29);
  re.RegisterShader3D export(1738-41).
- tr_backend.c: r_origfastsky color 0.8,0.7,0.4 (374-379).
- tr_scene.c: wrap refdef.text copy in #ifndef ELITEFORCE (306-308).
- tr_local.h: extern r_origfastsky (1711-12).
- Shared headers (lilium renderercommon ALREADY has these — verify): refEntity_t.data union, RT_* enum,
  RF_FULLBRIGHT/RF_FORCE_ENT_ALPHA, refdef text #ifndef, extensions_string 2*MAX, RegisterShader3D in
  refexport+tr_common.h.

## D. Platform Vulkan (sdl/sdl_glimp.c) — add a Vulkan window path:
- Window: create with SDL_WINDOW_VULKAN (not _OPENGL) when building Vulkan. SDL_Vulkan_LoadLibrary(NULL);
  qvkGetInstanceProcAddr = SDL_Vulkan_GetVkGetInstanceProcAddr().
- VK_GetInstanceProcAddr(instance,name) → SDL_Vulkan_GetVkGetInstanceProcAddr() result (wrap).
- VK_CreateSurface(instance,*surface) → SDL_Vulkan_CreateSurface(win,instance,surface).
- VKimp_Init(glconfig) → set glConfig.vidWidth/Height from SDL_Vulkan_GetDrawableSize (Android full-drawable
  override like the GL path), set up the window; VKimp_Shutdown → teardown.
- Keep the __ANDROID__ full-drawable override (vidWidth/Height = drawable). Landscape hint stays.

## E. CMake (android-port/EFAndroid/app/jni/src/CMakeLists.txt):
- Add option EF_RENDERER (gl2|vulkan). When vulkan: compile renderervk/*.c + renderervk/shaders/spirv/shader_data.c
  + renderercommon/*.c (NOT renderergl2/*, NOT glsl/*); define USE_VULKAN USE_VULKAN_API; do NOT link GLESv3/v2
  (keep EGL? not needed). Dynamic Vulkan load (no -lvulkan) — SDL provides loader.
- Manifest: minSdk 24 (already 24); add <uses-feature android.hardware.vulkan.version required=false>.
- SDL must be built with Vulkan support (SDL 2.30.9 has it). Window flag handled in sdl_glimp.

## F. Phase 2 (after it renders): pipeline PREWARM — after map+media load, call a new vk_prewarm_all_pipelines()
   that loops vk.renderPassIndex over enabled passes × all vk.pipelines_count calling vk_gen_pipeline(i)
   (idempotent). vk.c refs: vk_gen_pipeline(~6586), vk.pipelines_count, RENDER_PASS_COUNT. THE stutter fix.
   + optional VkPipelineCache disk serialize (UUID-validated).

## G. Phase 3: render thread (restore backEndData[2]+tr.smpFrame ping-pong; RB_ExecuteRenderCommands on
   SDL_Thread; per-frame VkFence; snapshot backend cvars; gate registration/readbacks). Vulkan removes the
   GL thread-affine-context problem.

## STATUS: gl2+JIT TESTABLE apk built. Vulkan = Phase 1 not yet compiling. Current target is
   compile+link; on-device rendering verification follows once the build is complete.
