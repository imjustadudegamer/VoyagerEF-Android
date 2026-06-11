# Render thread (SMP) — design & implementation

STATUS: implemented behind `r_smp` (default **0** = off). The proven
single-threaded path is byte-for-byte unchanged when `r_smp 0`. This is
RENDERER_BACKLOG.md optimization #2.

## Goal

Keep input/sim/cgame scene-build (the front-end) running at full rate while the
GPU command recording + submit + present + the `vkWaitForFences` throttle (the
back-end) run on a dedicated thread. With `NUM_COMMAND_BUFFERS 2` the GPU already
pipelines two frames deep, but today the whole back-end and the fence wait sit on
the main thread inside the *next* frame's `RB_DrawBuffer`; the front-end cannot
advance until the back-end of the previous frame has been recorded. A render
thread overlaps them.

## Why the substrate is clean

The front-end already talks to the back-end through ONE serialized byte arena,
`backEndData->commands` (filled by `R_GetCommandBuffer`), executed by
`RB_ExecuteRenderCommands(cmdList->cmds)` (tr_cmds.c). The back-end **never
dereferences the global `backEndData`** — it reads everything through pointers
embedded in the commands (`cmd->drawSurfs`, `cmd->refdef.*`). So double-buffering
the front-end's `backEndData` and handing the finished command list to a thread
is the canonical ioq3 SMP seam, and Quake3e/this fork already deleted all the old
SMP code, so there is nothing to fight.

## Architecture

```
main thread                          render thread
-----------                          -------------
build commands into backEndData[F]
RE_EndFrame
  R_IssueRenderCommands
    smpActive:
      WakeRenderer(cmds[F]) --------> RendererSleep returns cmds[F]
      smpFrame ^= 1                   RB_ExecuteRenderCommands(cmds[F])
      backEndData = buf[smpFrame]       vk_begin_frame (WaitForFences/Acquire)
  (returns; build next frame in [F^1]) record RB_* / vk_end_frame (submit)
                                        vk_present_frame (present)
                                       RendererSleep (park, signal completed)
```

- `backEndDataBuf[2]` allocated in `R_Init` (second buffer only when `r_smp`).
  `backEndData` is a pointer that always aims at the current front-end buffer
  `backEndDataBuf[tr.smpFrame]`. ALL existing `backEndData->` front-end writes are
  untouched; only the alloc + the flip point change. The back-end consumes the
  command's embedded snapshot, so the flip is invisible to it.
- Thread + sync primitives live in `sdl/sdl_glimp.c` (SDL_Thread/mutex/cond),
  exposed through `refimport_t` (ri.GLimp_SpawnRenderThread / RendererSleep /
  FrontEndSleep / WakeRenderer / ShutdownRenderThread), the ioq3-canonical layout.
  The renderer's `RB_RenderThread` wrapper loops `RendererSleep → RB_ExecuteRenderCommands`.

## The hard part: Vulkan resource safety

`vk.queue`, `vk.descriptor_pool`, `vk.pipelines[]`, the swapchain and all sync
objects are shared. In steady state ONLY the render thread touches Vulkan. The
invariant that makes this safe:

> Any front-end operation that must call Vulkan first calls `R_SyncRenderThread()`,
> which (when smpActive) blocks until the render thread is parked. The op then runs
> while the render thread holds no Vulkan state, so access is exclusive. These ops
> are synchronous main-thread calls, so the render thread stays parked for their
> whole duration (no frame is issued meanwhile).

`R_SyncRenderThread()` is a no-op when `!glConfig.smpActive`, so default builds pay
nothing. Guards were added at every front-end→Vulkan chokepoint:

| Site | File | Covers |
|---|---|---|
| `R_CreateImage` | tr_image.c | every texture/lightmap/scratch/font upload (descriptor alloc + queue copy) |
| `FinishShader` (pipeline block) | tr_shader.c | eager pipeline creation + `vk.pipelines[]`/count mutation |
| `RE_BeginRegistration` | tr_model.c | registration boundary |
| `RE_EndRegistration` | tr_init.c | the prewarm sweep (creates hundreds of pipelines) |
| `RE_LoadWorldMap` | tr_bsp.c | world VBO build + lightmaps |
| `RE_StretchRaw` | tr_backend.c | cinematic raw upload (uploads + draws inline, not via cmd buffer) |
| `RE_Shutdown` | tr_init.c | joins the thread before `vk_release_resources`/`vk_shutdown` (stronger than sync) |

Screenshots / AVI capture (`backEnd.screenshotMask != 0`) write files via `ri.FS_*`
from inside the back-end; those frames are run **synchronously on the main thread**
(after `FrontEndSleep`) instead of being handed off, so no `ri.FS_*` runs on the
render thread.

## Known limitations (acceptable for an opt-in flag)

- A FATAL Vulkan error (device lost) on the render thread calls `ri.Error`, whose
  `Com_Error` longjmps to the main thread's setjmp — undefined across threads. In
  practice this only fires on device loss (fatal regardless). Not hardened.
- `ri.Printf` may interleave with the main thread's console writes (cosmetic).
- `CL_IsMinimized()` is still polled multiple times inside the back-end and can
  flip mid-frame (pre-existing backlog #4). In SMP the main thread gates handoff on
  minimized, so the render thread does not run while minimized; a background
  transition mid-render-frame remains the same rare hazard as single-threaded.
- `vk_restart_swapchain` runs on the render thread (surface-lost/resize). The
  Android surface signals (`com_minimized`) arrive on the activity/main thread and
  are observed at frame boundaries; the render thread only restarts when it owns
  the frame. Heavy rotation/resize churn under r_smp is not exercised.

## Files touched

- renderercommon/tr_public.h — 5 refimport fn pointers.
- client/cl_main.c — declare + assign them in CL_InitRef.
- sdl/sdl_glimp.c — GLimp_SpawnRenderThread/RendererSleep/FrontEndSleep/WakeRenderer/ShutdownRenderThread.
- renderervk/tr_local.h — backEndDataBuf[2], trGlobals.smpFrame, r_smp, prototypes.
- renderervk/tr_init.c — r_smp cvar, 2-buffer alloc, R_InitCommandBuffers/R_ShutdownCommandBuffers/RB_RenderThread/R_SyncRenderThread, spawn in R_Init, join in RE_Shutdown, sync in RE_EndRegistration.
- renderervk/tr_cmds.c — SMP handoff + buffer flip in R_IssueRenderCommands.
- renderervk/tr_image.c, tr_shader.c, tr_bsp.c, tr_model.c, tr_backend.c — R_SyncRenderThread guards.
