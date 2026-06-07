# Pipeline prewarm — design

STATUS: parts 1 and 2 implemented and verified on device (444 pipelines /
270 defs in ~130 ms on a 2023 Adreno, ~370 ms on a 2016 Adreno — behind the
load screen, zero hitch warnings in play). Part 3 (disk-serialized
VkPipelineCache) remains optional follow-up work.

## The problem, precisely

All SPIR-V is precompiled and embedded, so the only on-device compilation is
`vkCreateGraphicsPipelines`. Pipelines are keyed by the full `Vk_Pipeline_Def`
struct in `vk.pipelines[]` (`vk.h:174-196`), with one `VkPipeline` handle per
render pass type (`MAIN` / `SCREENMAP` / `POST_BLOOM`). Creation is decoupled
from registration:

- `vk_find_pipeline_ext(..., use)` (`vk.c:6690`) records the def; it compiles
  immediately only when `use == qtrue`.
- Otherwise the handle stays `VK_NULL_HANDLE` until the first
  `vk_bind_pipeline` → `vk_gen_pipeline` (`vk.c:7194`, `vk.c:6675`) — a
  mid-frame `vkCreateGraphicsPipelines` call. **That is the hitch.**

What is already eager at map load (per-stage, in `FinishShader`,
`tr_shader.c:3601-3635`): the main-pass primary pipeline and its
depth-fragment variant. Everything else is lazy:

| Lazy pipeline | First triggered by | Where |
|---|---|---|
| mirror / mirror-df variants (per stage) | first portal/mirror view | `tr_shader.c:3604,3612` |
| fogCollapse `fog_stage=1` variants (per stage) | first draw inside a fog volume | `tr_shader.c:3628-3629` |
| PMLIGHT dlight pipelines (48 defs; `r_dlightMode` defaults to 1 on Android) | first dynamic light (weapon fire/explosion) hitting a surface | `vk.c:3139,3141`, bound `tr_shade.c:1240` |
| `RF_FORCE_ENT_ALPHA` blended variants (EF-specific: transporter, cloak, corpse fade, forcefields) | first such effect on screen; **def doesn't even exist until then** (allocated at draw time) | `tr_shade.c:1032-1054` |
| beam / axis / shadow pipelines | first use | `vk.c:3061,3074,3155,3167` |
| every def's non-MAIN render-pass handle | first screenmap/bloom-pass bind | `vk.c:6675-6687` |

Upstream Quake3e has no prewarm either (verified against current master +
issue tracker) — this lazy split is inherited, and desktop drivers hide it.
Mobile drivers don't: a cold `vkCreateGraphicsPipelines` on a mid-range
mobile driver costs **~30 ms** (Samsung GDC measurement) — i.e. two dropped
frames per new effect — and ~0.5-1 ms even with a warm driver cache.

## The fix (three parts, in priority order)

### 1. Pre-derive the `RF_FORCE_ENT_ALPHA` defs at shader finish

The draw-time def rewrite (`tr_shade.c:1048-1049`: state_bits →
`GLS_SRCBLEND_SRC_ALPHA | GLS_DSTBLEND_ONE_MINUS_SRC_ALPHA`, depthmask
cleared) is mechanical. Apply the same transform per opaque stage in
`FinishShader` and register the def with `use = qfalse`. After this, **every
pipeline the map can ever need has a def in `vk.pipelines[]` by the end of
registration** — which makes the sweep below exhaustive. Slot budget is fine:
`MAX_VK_PIPELINES` = 2304 vs ~50-300 defs per map (instrument and confirm).

### 2. `vk_prewarm_pipelines()` in `RE_EndRegistration`

`RE_EndRegistration` (`tr_init.c:2017`) is the canonical hook: the engine
calls it from `CL_InitCGame` (`cl_cgame.c:1197`) after cgame has registered
all media, while the loading screen is still up. Under `USE_VULKAN` it
currently only calls `vk_wait_idle()` — the empty slot the original plan doc
reserved for exactly this.

```
for pass in (RENDER_PASS_MAIN [, RENDER_PASS_POST_BLOOM if r_bloom]):
    for i in 0 .. vk.pipelines_count:
        if vk.pipelines[i].handle[pass] == VK_NULL_HANDLE:
            create_pipeline(&def, pass, i)      // no command buffer needed
print "Prewarmed %d pipelines in %d ms"          // ri.Milliseconds
```

Notes:
- `create_pipeline` directly per pass (or temporarily set
  `vk.renderPassIndex` and reuse the idempotent `vk_gen_pipeline`).
- **Skip `RENDER_PASS_SCREENMAP`**: it only runs for extended-shader
  `screenMap` stages (`tr_shader.c:666-684`), absent from stock EF content.
  If `tr.needScreenMap` is ever set, prewarm those defs then.
- `POST_BLOOM` handles only matter while bloom is enabled (default on
  Android) for pipelines bound after the bloom composite (HUD/2D). Loading
  screens already warm the common 2D ones naturally; measure whether the
  pass-2 sweep is worth its cost, gate on `r_bloom`.
- Synchronous on the load path is the right baseline: ~100-300 defs ×
  sub-ms-to-few-ms ≈ tens to a few hundred ms behind the load screen.
  (Threaded creation is spec-legal — `vkCreateGraphicsPipelines` is
  internally synchronized — but at least one mobile vendor serializes all
  compilation on one driver thread, so don't add threads without measuring.)
- Runs naturally on every map load and after `vid_restart` (both re-enter
  `CL_InitCGame`). Also call it at the end of `vk_restart_swapchain`
  (`vk.c:3884`), which currently destroys all handles and relies on lazy
  regen — with the in-memory cache that re-sweep is nearly free.

### 3. Persist the `VkPipelineCache` to disk (optional but cheap)

`vk.pipelineCache` exists (`vk.c:4415`) and feeds every world-pipeline
creation, but is created empty each run and never serialized — and Android
has **no OS-level Vulkan blob cache** (unlike GLES). Add zeux-style
serialization:

- Save right after the prewarm sweep finishes (NOT at app exit — Android
  kills processes without warning), via temp file + atomic rename.
- Wrap in our own header: magic, size, hash, vendorID, deviceID,
  driverVersion, pipelineCacheUUID — drivers are known to fail UUID
  validation across updates, and Adreno/Mali drivers are Play-Store
  updatable now, so self-validation is mandatory.
- Load into `VkPipelineCacheCreateInfo::pInitialData` in `vk_initialize`;
  on any mismatch or `vkCreatePipelineCache` failure, fall back to empty.
- Store under `fs_homepath` (direct file I/O — the engine's pure-FS rules
  apply to game VFS reads, not renderer-private files). One file, e.g.
  `vk_pipeline_cache.bin`.
- Effect: first-run map loads pay full compile cost once; every later run
  loads ~40x faster per pipeline (Samsung: 30 ms → ~0.7 ms each).
- Also pass `vk.pipelineCache` to the gamma/bloom/blur pipeline creation
  (`vk.c:5497,5666` currently pass `VK_NULL_HANDLE`) so post-process
  recreation on swapchain restarts hits the cache too.

## Instrumentation (do this first)

- `vk.pipeline_create_count` already counts creations (`vk.c:6652`,
  printed by `gfxinfo`). Log it at `RE_EndRegistration` and at map end to
  measure how many pipelines the prewarm covers vs how many still leak to
  draw time.
- Time the sweep with `ri.Milliseconds`. (`VULKAN_RENDERER.md`'s claim that
  `Sys_Microseconds` exists is stale — it was never added; ms is enough for
  the summary line, mirror `GLSL_WarmupShaders`' print format,
  `tr_glsl.c:733-811`.)
- The engine's `Hitch warning:` print (`common.c:3161`) is the end-to-end
  acceptance check: play a map, fire every weapon, transport — expect zero
  pipeline-related hitch warnings after the fix.

## What this doesn't fix

- The arc-welder beam not rendering is a correctness bug in the EF entity
  surface path, unrelated to pipelines (tracked separately).
- Mid-game `trap_R_RegisterShader` calls by mods would still parse + upload +
  compile at call time. Stock EF registers everything at level start; accept
  the residual risk.

## Source notes

Design validated against: upstream Quake3e master (no prewarm exists there;
eager-at-registration for main pass only), vkQuake / vkQuake2 (create all
pipelines before gameplay, the genre norm), Godot 4.4 (ubershader + async
compile — overkill for a double-digit-per-map pipeline count), Unreal PSO
precaching (load-time compile with timeout), ARM & Qualcomm vendor guides
("build pipelines during initialization", never at draw), Khronos
pipeline-cache sample (Mali-G76: 50.4 ms uncached vs 24.4 ms cached set
recreation), zeux's pipeline-cache-serialization writeup (header validation),
and the original VULKAN_PORT_PLAN.md / VULKAN_PORT_WORKLIST.md Phase 2 design
(git `a587cad`, removed from the public tree).
