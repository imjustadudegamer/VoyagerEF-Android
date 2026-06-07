# AArch64 QVM JIT — implementation dossier

STATUS (2026-06-07): implemented and shipping — steps 1-6 of §4 landed (universal
armv7+arm64 APK, JIT on both ABIs). First light on device: all three QVMs compile
(ui 423 KB / cgame 445 KB / qagame 600 KB of native code, ~15 ms each) and full bot
matches run clean with `vm_rtChecks 15` on both a Mali-G78 phone and an Adreno 740
handheld, 64-bit Vulkan ICDs included.

Hardening (2026-06-07, v0.9.4): scripted soaks (bot match -> map_restart x2 ->
vid_restart -> map change) pass clean under both codegen modes (vm_rtChecks 15 and
0/forceDataMask). One finding: with strict checks (15), retail EF gamecode
occasionally performs a benign out-of-range READ (non-deterministic, bot/event
dependent) — the interpreter and armv7 JIT have always silently masked these, so
the default is now **vm_rtChecks 7** (pstack+opstack+jump armed, data masked,
matching established EF semantics); 15 stays available for VM/JIT debugging.
Measured (idle-scene bot match, big-core phone): server VM 0.18 -> 0.10 ms/frame
JIT vs interpreter; total frame renderer-bound either way — the JIT's headroom
matters in heavy scenes and on small cores. Still open: interpreter-vs-JIT demo
divergence comparison, mixed-device netplay determinism.

The plan as written before implementation follows: porting Quake3e's `vm_aarch64.c`
bytecode compiler into this port so arm64-v8a
builds run cgame/qagame/ui at native speed instead of the interpreter. The interpreter
is the documented arm64 bottleneck (`EFAndroid/app/jni/src/CMakeLists.txt:112-115`),
and Play's 64-bit requirement makes this a release prerequisite
(`EFAndroid/app/build.gradle:17-23`).

Donor: `quake3e-ref/code/qcommon/vm_aarch64.c` (2388 lines,
byte-identical to Quake3e master at/after commit `c84ea98`, 2026-05-19 — verified
against raw GitHub; every known upstream fix is already in our snapshot, nothing to
backport). It `#include`s `vm_optimize.h` (1491 lines) at vm_aarch64.c:792 — that file
ships with it.

Target: the efcode VM core (`EFAndroid/app/jni/efcode/qcommon/`), which is
byte-identical to stock lilium-voyager/ioq3 — `diff -u` of vm.c / vm_local.h /
vm_armv7l.c / vm_interpreted.c against `lilium-voyager-master/code/qcommon/` is empty,
and none of those files reference `ELITEFORCE`. EF-ness lives entirely in the trap
tables of cl_cgame.c / cl_ui.c / sv_game.c, which the JIT never sees.

## 1. Strategy

Two candidates were assessed:

- **(a) Graft the donor onto the existing ioq3-style vm.c** — copy vm_aarch64.c +
  vm_optimize.h, lift the ~700-line instruction pre-pass block from quake3e vm.c
  verbatim, append a handful of vm_t fields, write ~150 lines of glue. **Chosen.**
- **(b) Replace vm.c/vm_local.h wholesale with Quake3e's** — drags in `VM_Create` /
  `VM_Call` signature changes at 49+ call sites, replaces the pure-FS-sensitive QVM
  loading path (this port ships assets in pk3 precisely because loose files vanish
  under pure FS), removes `currentVM`/`VM_ArgPtr`/`VM_BlockCopy` that EF's syscall
  handlers and the armv7l JIT depend on, and forces a second JIT re-port (Quake3e's
  vm_armv7l). No codegen benefit over (a). Rejected.

Rationale for (a): it keeps the proven armv7l JIT, the interpreter, the pure-FS QVM
loading, and all engine call sites untouched; the risky surface is two new files plus
glue. The pre-pass block is demonstrably dependency-free — a host harness compiled it
verbatim (zero source edits) and ran all 16 retail/community EF QVMs through
`VM_CheckInstructions` cleanly (see §8). The in-tree precedent is the same pattern:
renderervk was imported with an additive compat shim, not by importing Quake3e's
engine core (`VULKAN_RENDERER.md`).

A third option — World of Padman's fresh ~1145-line port of vm_armv7l.c to aarch64,
which needs zero vm.c changes — is the fallback if the graft stalls (§7). It lacks
Quake3e's optimizer and bytecode validation, so it's plan B, not plan A.

**Bring-up order**: interpreter-only arm64 build first (one-line gradle change,
already compiles — stale arm64 intermediates exist under
`app/build/intermediates/cxx/`), validated on device, then the JIT on top. This
separates "arm64 ABI works at all" (incl. the 64-bit GPU driver switch, §8) from "JIT
is correct".

## 2. Donor analysis — what vm_aarch64.c is and needs

Architecture (donor file refs):

- Two-pass compile via `NUM_PASSES 1` + `goto __recompile` (vm_aarch64.c:42-45,
  2259-2287). Pass 0 measures exactly (emit() only advances `compiledOfs` when
  `code == NULL`, :300-308) and fills `vm->instructionPointers[]` with relative
  offsets; pass 1 emits. Layout must be byte-identical between passes —
  `emit_MOVXi64` (:741-747) exists solely because the prologue's literal-pool base is
  NULL in pass 0 and a real pointer in pass 1 (upstream bug #399).
- Pinned registers (:89-135): R19 litBase, R20 `vm_t*`, R21/R22 opStack/opStackTop,
  R23 instructionPointers, R24 programStack, R25 stackBottom, R26 dataBase,
  R27 dataMask, R28 procBase. R18 (platform reg) never used. All reg-offset
  loads/stores use UXTW extend (e.g. :451) — 32-bit VM address zero-extended onto the
  64-bit dataBase in one instruction; this is the central 32→64 correctness device.
- ARMv8.0 base + scalar FP only — no LSE/NEON/v8.1+; runs on every arm64-v8a device.
  Plain BR/BLR (no BTI/PAC variants) — fine, see §6.
- Optimizer (`vm_optimize.h`): virtual opStack with values cached in registers,
  dynamic LRU allocators, const cache, load/store register↔memory mapping cache,
  const-fusion (`ConstOptimize`, :1327-1508) incl. inlined TRAP_SQRT/SIN/COS,
  addressing-mode folding, single-epilogue returns. All gated by toggles at :53-71.
- Syscalls are fully emitted (no C trampoline): `FUNC_SYSC/FUNC_SYSF` (:1161-1223)
  negate the call number, publish `vm->programStack`, build an `intptr_t args[16]`
  array on the native stack with sign-extending LDRSW loads, and `BLR` through
  `offsetof(vm_t, systemCall)`. Semantically identical to efcode armv7l's `asmcall`
  64-bit branch (vm_armv7l.c:232-245).
- Block copy is fully emitted too (`emitBlockCopyFunc`, :1227-1269; 12-byte vec3 copies
  inlined). The donor never calls `VM_BlockCopy`.
- Runtime checks (programStack/opStack overflow, jump bounds, data bounds), gated by
  the `vm_rtChecks` cvar bitmask (1=pstack 2=opstack 4=jump 8=data), routed to
  noreturn stubs that call `Com_Error(ERR_DROP)` (:265-298, 2225-2255) — same error
  model as armv7l's `ErrJump`. Non-jump-target `instructionPointers[]` entries are
  poisoned to `BadJump` (:2303-2310).
- Memory: `mmap(PROT_WRITE)` → emit → `mprotect(PROT_READ|PROT_EXEC)` →
  `__clear_cache` (:2274, :2325, :2332). Exact allocation, no retry loop. On
  mmap/mprotect failure it frees buffers and returns qfalse → interpreter fallback.

Porting gap list (everything the donor needs that efcode lacks), verified against
efcode vm.c/vm_local.h:

1. **Instruction pre-pass machinery** — `instruction_t`, `opcode_info_t ops[OP_MAX]`,
   `opname[]`, `VM_LoadInstructions` (q3e vm.c:1151), `VM_CheckInstructions`
   (q3e vm.c:1233, incl. `safe_address`, `VM_Fixup`, `VM_IgnoreInstructions`,
   `InvertCondition`, `VM_FindLocal`). ~700 lines, lifts verbatim; depends only on
   Com_*/LittleLong/sprintf. The single largest item. `VM_ReplaceInstructions`
   (Q3-mod CRC patches) stubs to empty.
2. **vm_t fields** — add `int32_t *opStack, *opStackTop` (set per-call by
   VM_CallCompiled, read by the emitted prologue via offsetof), `uint32_t
   exactDataLength`, `qboolean forceDataMask`. All donor access is `offsetof`-based,
   so fields are **appended**; efcode's "DO NOT MOVE" header (programStack@0,
   systemCall@4, vm_local.h:141-148) stays untouched.
3. **codeBase type** — donor uses a `vmFunc_t` union and calls
   `vm->codeBase.func()`; efcode has `byte *`. Keep byte* (armv7l has ~10 refs) and
   cast at the donor's single call site.
4. **Signatures** — donor: `qboolean VM_Compile(vm_t*, vmHeader_t*)` /
   `int32_t VM_CallCompiled(vm_t*, int nargs, int32_t*)`. efcode (vm_local.h:192-193):
   `void VM_Compile` / `int VM_CallCompiled(vm_t*, int *args)`. Adapt the donor;
   failure signalling becomes `vm->compiled = qfalse` + return, which efcode's
   VM_Create already handles (vm.c:668-672 falls back to `VM_PrepareInterpreter`).
5. **Arg marshalling** — donor reserves `(MAX_VMMAIN_CALL_ARGS+2)*4 = 24` bytes and
   copies 4 args; efcode's VM_Call passes a 13-int frame (`MAX_VMMAIN_ARGS`,
   vm_local.h:27) and armv7l reserves `8 + 4*13`. Same layout (args at
   programStack+8), different count — copy 13. Generated code doesn't care; args flow
   through VM memory.
6. **currentVM** — donor's VM_CallCompiled doesn't set it (the global doesn't exist in
   quake3e vm.c); efcode's syscall handlers resolve every pointer through
   `VMA → VM_ArgPtr → currentVM->dataBase` (vm.c:748-762). The adapted
   VM_CallCompiled must set `currentVM = vm` like vm_armv7l.c does.
7. **Data guard region** — donor's "safe" (unmasked) stores and check-elision assume
   `VM_DATA_GUARD_SIZE` (1024) bytes beyond the pow2 data region (q3e vm.c:854,
   `safe_address` allows proc->value + 256); efcode allocates `dataLength + 4` only
   (vm.c:455). Must enlarge the guard (and record `exactDataLength` pre-rounding).
8. **vm_rtChecks cvar** — register in VM_Init, default "15", CVAR_INIT|CVAR_PROTECTED
   (quake3e registers it in common.c:3797-3800). Fits this port's established
   cvar-bisect debugging loop.
9. **Cosmetics** — `S_COLOR_WARNING/S_COLOR_ERROR` → map to YELLOW/RED (2 lines);
   `OP_MAX` sentinel appended to efcode's opcode enum (values otherwise identical);
   donor's `vm->codeSize` dropped (munmap `codeLength` like armv7l).
10. **Trap inlining is safe as-is** — `ConstOptimize` inlines `~TRAP_SQRT/SIN/COS`
    (:1404-1426) assuming Q3 shared trap numbers. Verified: efcode has the identical
    `sharedTraps_t { TRAP_MEMSET = 100, ... }` (qcommon.h:376-393) and the EF module
    enums anchor identically (CG_MEMSET=100 → CG_SIN=103/CG_SQRT=106; UI_MEMSET=100;
    sv_game.c:875-885 handles TRAP_SIN/SQRT). No renumbering needed; add a one-shot
    runtime sanity test anyway (§8).
11. **Not needed** — `Load_JTS`/.jts files (needs `fs_lastPakIndex`; drop — retail EF
    QVMs are VM_MAGIC v1, `jumpTableTargets == NULL`, and VM_CheckInstructions'
    `__noJTS` path handles that), `sortedSyscalls`, errJump tables, `crc32sum`/
    `vmIndex_t` (only consumers are the stubbed VM_ReplaceInstructions and JTS).

## 3. Target contract — what the backend must satisfy

From efcode vm.c (VM_Create flow, vm.c:576-687):

- Engine allocates `vm->instructionPointers` (vm.c:648-649); VM_Compile fills it.
  Meaning of entries is backend-private (armv7l stores codeBase-relative offsets; the
  donor stores absolute addresses after the `+ codeBase` fixup pass).
- VM_Compile must set `vm->codeBase` (backend-owned mmap), `vm->codeLength`,
  `vm->compiled = qtrue`, `vm->destroy = VM_Destroy_Compiled` (called from VM_Free
  before the struct memset; must munmap). On failure: clear `vm->compiled`, free
  mappings, return — VM_Create falls back to the interpreter (vm.c:668-672).
- VM_CallCompiled(vm, int *args): args = `{callnum, a0..a11}` (13 ints). Reference
  implementation vm_armv7l.c:1168-1222: set `currentVM`/`currentlyInterpreting`;
  `programStack -= 8 + 4*13`; memcpy args to `image[programStack+8]`;
  `image[programStack+4] = 0`, `image[programStack+0] = -1`; opStack is a **local**
  array owned by VM_CallCompiled (donor model: `int32_t opStack[MAX_OPSTACK_SIZE]`
  with `opStack[0] = 0xDEADC0DE` canary, published via the new `vm->opStack/
  opStackTop` fields; donor's generated entry takes no arguments — it reads everything
  from vm_t through the baked R20). Post-call canary + programStack checks, restore,
  return `opStack[1]`.
- Recursion is supported and load-bearing: the syscall path publishes
  `vm->programStack` before calling out so a re-entrant VM_Call stacks correctly
  (armv7l asmcall :230; donor FUNC_SYSF :1196-1197 — already does this).
- `vm->systemCall` is `intptr_t (*)(intptr_t *args)` with `args[0]` = positive callnum,
  `args[1..15]` = sign-extended 32-bit VM args (`MAX_VMSYSCALL_ARGS` 16). Donor's
  emitted trampoline matches this exactly; the engine is already 64-bit clean here
  (the interpreter's own widening branch, vm_interpreted.c:504-511, proves it).
- QVM format: stock ioq3 `vmHeader_t` (qfiles.h:53-70), VM_MAGIC and VER2 both
  accepted; retail EF QVMs are VM_MAGIC (no jump tables). Data = data+lit+bss rounded
  up to pow2; `dataMask = pow2 - 1`; `programStack` starts at `dataMask + 1`
  (vm.c:681). `OPSTACK_SIZE` 1024 bytes; `PROGRAM_STACK_SIZE` 0x10000.
- VM_Restart reloads data with `alloc=qfalse` and does **not** recompile — codeBase
  must survive untouched.
- vm_cgame/vm_game/vm_ui default to "2" = VMI_COMPILED (vm.c:73-75) — once the
  backend is linked and NO_VM_COMPILED dropped for arm64, it activates automatically.

EF-specific quirks: none in the VM core (it is stock ioq3). The quirks are
environmental: pure-FS asset loading must not be disturbed (why strategy (b) was
rejected), and EF QVMs are 2000-era q3lcc output — empirically shallow (max per-proc
opStack 32 bytes vs the 120-byte `PROC_OPSTACK_SIZE` ceiling, §8).

## 4. Implementation plan

Canonical-tree rule first: `build-all.sh:13-16` rsyncs `--delete` from
`lilium-voyager-master/code/` into `jni/efcode/`. **All edits below go into
`lilium-voyager-master/code/qcommon/`** (the canonical tree),
or the next build wipes them.

1. **arm64 interpreter bring-up.**
   Files: `EFAndroid/app/build.gradle:23` (`abiFilters 'armeabi-v7a', 'arm64-v8a'`,
   rewrite the warning comment at :17-22).
   Accept: universal APK installs on an arm64 device, loads arm64 libs (`adb shell
   getprop`/maps check), game reaches in-game with `vminfo` showing interpreted;
   renderer regressions triaged separately (64-bit GPU driver switch, §8). Expect and
   accept interpreter-speed stutter at this step.

2. **vm_local.h additions.**
   Files: `qcommon/vm_local.h`. Append `OP_MAX` to the opcode enum; add
   `instruction_t`, `opcode_info_t` + `extern ops[]`, `JUMP`/`FPU` flags,
   `PROC_OPSTACK_SIZE 30`, `MAX_OPSTACK_SIZE 512`, `VM_DATA_GUARD_SIZE 1024`,
   `VM_RTCHECK_*` flags (all from q3e vm_local.h:38-52, 143-153, 246-257); append to
   vm_t: `int32_t *opStack, *opStackTop; uint32_t exactDataLength; qboolean
   forceDataMask;`; prototypes for VM_LoadInstructions/VM_CheckInstructions.
   Accept: armv7 build still compiles and runs unchanged (fields appended, offsets
   0/4 preserved; vm_armv7l.c uses entry args, not the new fields).

3. **vm.c: pre-pass block + loader tweaks.**
   Files: `qcommon/vm.c`. Paste verbatim from q3e vm.c: `ops[]`+`opname[]` (:39-204),
   `VM_IgnoreInstructions` (:938), `InvertCondition` (:950), `VM_FindLocal` (:988),
   `VM_Fixup` (:1026), `VM_LoadInstructions` (:1151), `safe_address` (:1206),
   `VM_CheckInstructions` (:1233-1642), minus the JTS-file branches. Stub
   `VM_ReplaceInstructions` empty. In VM_LoadQVM: record
   `vm->exactDataLength = dataLength + litLength + bssLength` before pow2 rounding;
   change `dataAlloc = dataLength + 4` (vm.c:455) to `+ VM_DATA_GUARD_SIZE`. Register
   `vm_rtChecks` ("15", CVAR_INIT|CVAR_PROTECTED) in VM_Init.
   Accept: armv7 + arm64 interpreter builds compile and run (the new code is inert
   until the backend calls it); optional host harness re-run (§8) on the paks.

4. **Copy vm_optimize.h + vm_aarch64.c; adapt.**
   Files: new `qcommon/vm_optimize.h` (verbatim), new `qcommon/vm_aarch64.c` with
   these edits (~60 lines): `vm->codeBase.ptr/.func` → byte* + cast at the call site;
   `VM_Compile` → void, failure = `vm->compiled = qfalse; return;`;
   `VM_CallCompiled(vm_t*, int *args)` — copy `MAX_VMMAIN_ARGS` (13) args at
   `image[programStack+8]`, set `currentVM = vm` and `currentlyInterpreting`, keep
   the local opStack + canary + `vm->opStack/opStackTop` publication;
   `S_COLOR_WARNING/ERROR` → YELLOW/RED; drop `codeSize`; keep the file's
   GPL2+ header intact and add a provenance line ("based on Quake3e's vm_aarch64.c,
   Copyright (C) 2020-2026 Quake3e project").
   Accept: compiles clean for arm64-v8a via `./build-native.sh arm64-v8a` (script is
   already ABI-parameterized, build-native.sh:23).

5. **Build wiring.** See §5. Accept: arm64 libmain.so links `VM_Compile` from
   vm_aarch64.c; `NO_VM_COMPILED` absent from its compile flags; armv7 build
   byte-unchanged.

6. **First-light on device.**
   Accept: device boots to menu (ui.qvm compiled — `vminfo` says compiled), starts
   a map (cgame+qagame), bot match runs several minutes. `vm_rtChecks 15` throughout.
   On any Com_Error from a check stub, capture which (BADJ/OUTJ/PSOF/OSOF/BADR/BADW
   message text) — that localizes the bug class immediately.

7. **Hardening passes.**
   - Run with `vm_rtChecks 0` (mask-everything mode via forceDataMask, :1592-1596)
     and `15`; both must survive a full bot match + map changes + vid_restart +
     map_restart (VM_Restart path: data reload without recompile).
   - Toggle optimizer defines off/on (CONST_OPTIMIZE, LOAD_OPTIMIZE, CONST_CACHE_RX —
     historically the buggy one) if misbehavior appears; this is the JIT equivalent of
     the cvar-bisect loop.
   - Verify float behavior: NaN-sensitive paths (forcefields, beam math) — donor
     already has the MI/LS fix, this is regression confirmation.
   Accept: no SIGILL/SIGBUS/SIGSEGV in logcat across a long session; interpreter vs
   JIT demo playback diverges nowhere obvious (same game state on a timed demo).

8. **Perf validation + release.**
   Files: `README.md` (drop the armv7-only note, :36-41,103), `build.gradle:12-13`
   version bump.
   Accept: measurable frame-time improvement vs the step-1 interpreter build
   (the original GL-stutter profiling methodology applies); both ABIs in one
   universal APK (~5-6 MB, fine for the GitHub-release flow — no splits).

## 5. Build-system changes (exact)

`EFAndroid/app/jni/src/CMakeLists.txt:35-40` — replace the arch switch:

```cmake
if(CMAKE_ANDROID_ARCH_ABI STREQUAL "armeabi-v7a")
  list(APPEND QCOMMON_SRC ${EF}/qcommon/vm_armv7l.c)
  set(EF_VM_JIT TRUE)
elseif(CMAKE_ANDROID_ARCH_ABI STREQUAL "arm64-v8a")
  list(APPEND QCOMMON_SRC ${EF}/qcommon/vm_aarch64.c)
  set(EF_VM_JIT TRUE)
else()
  set(EF_VM_JIT FALSE)
endif()
```

`NO_VM_COMPILED` then drops out automatically via the genex at :98. Update the
comment at :33-34.

`EFAndroid/app/build.gradle:23`:

```groovy
abiFilters 'armeabi-v7a', 'arm64-v8a'
```

(and rewrite the do-not-add-arm64 comment above it). Keep armv7 in the APK for
32-bit-only legacy devices.

Everything else is already in place — verified, not assumed:

- `q_platform.h:159-165` forces NO_VM_COMPILED for `__aarch64__` **only inside the
  `__APPLE__` block**; Linux/Android path needs no header change.
- NDK 25.1.8937393 / CMake 3.31.5 / AGP 8.7.2 all arm64-ready; SDL 2.30.9 is built
  from source per-ABI and has compiled for arm64 before (stale intermediates, LOAD
  align 0x4000 confirmed with readelf).
- 16 KB page alignment: `-Wl,-z,max-page-size=16384` is already global
  (`jni/CMakeLists.txt:7`) and AGP ≥8.5.1 zip-aligns uncompressed libs — the Play
  16 KB requirement (Nov 2025, targetSdk 35+) is already satisfied.
- `ARCH_STRING="${CMAKE_ANDROID_ARCH_ABI}"` (:104) is cosmetic-only (cvar `arch`,
  dead dlopen paths) — leave it.
- No Java/JNI changes: library loading is name-based (`SDLActivity.getLibraries()`),
  asset extraction is path-based and arch-neutral.

## 6. Android platform rules

W^X is a non-issue on stock Android: `allow appdomain self:process execmem` covers
both anonymous PROT_EXEC mmaps and RW→RX mprotect for untrusted apps on every Android
13-16 release, with no targetSdk dependence. The armv7l JIT already exercises exactly
this path on device (vm_armv7l.c:628, :1156, :1162). The one behavioral change to
carry: hardened ROMs (GrapheneOS) can deny execmem per-app, so mmap/mprotect failure
must **fall back to the interpreter, never Com_Error fatally** — the adapted
VM_Compile failure path (§4 step 4) covers this.

Canonical sequence (donor already does this at vm_aarch64.c:2274/2325/2332; two
tweaks marked):

```c
/* 1. Allocate RW — never RWX. MAP_PRIVATE, not the donor's MAP_SHARED (tweak #1). */
code = mmap(NULL, allocSize, PROT_READ|PROT_WRITE,
            MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
if (code == MAP_FAILED) { vm->compiled = qfalse; return; }   /* tweak #2: no DIE */

/* 2. Emit. No bti/pac instructions. No hardcoded 4096 anywhere
      (use sysconf(_SC_PAGESIZE) if alignment math is ever needed). */

/* 3. Seal once — QVM code is immutable after compile, never reopen RW. */
if (mprotect(code, codeLength, PROT_READ|PROT_EXEC) != 0) {
    munmap(code, allocSize); vm->compiled = qfalse; return;
}

/* 4. Flush on the same thread that will first execute (SDL_main thread —
      QVMs compile and run there). */
__builtin___clear_cache((char*)code, (char*)code + codeLength);
```

Specifics:

- **I-cache**: there is no cacheflush(2) on arm64; `__builtin___clear_cache` emits
  `dc cvau` / `dsb ish` / `ic ivau` / `dsb ish` / `isb` with the line size read from
  `CTR_EL0` per call. The historical big.LITTLE mismatched-line-size bug (Exynos 8890)
  is dead: NDK r23+ compiler-rt doesn't cache CTR_EL0 and kernels ≥4.9 report the
  system-wide safe minimum — every Android 13+ device qualifies. Flush **after**
  mprotect (RX pages are readable; this is the donor's order — keep it).
- **BTI/PAC**: nothing to do. NDK doesn't enable `-mbranch-protection` by default, and
  anonymous mappings never get `PROT_BTI` implicitly, so no `bti c` landing pads are
  needed in emitted code. PAC only affects compiler-signed prologues. ARMv8.2 cores
  can't even fault on either; ARMv9 devices could if branch protection were ever
  enabled — at that point remember plain mprotect(RX) drops PROT_BTI.
- **MTE**: no interaction. Don't set `android:memtagMode`; instruction fetch is never
  tag-checked, and the JIT pages have no PROT_MTE.
- **16 KB pages**: mmap-then-mprotect-same-base is automatically granule-correct; the
  only bug class is hardcoded 4096 or sub-region mprotect at computed offsets — the
  donor has neither. The .so side is already handled (§5).
- **Dual-mapping / MAP_JIT**: not needed on Android (iOS/macOS-arm64 mechanisms).
  Compile-once → seal → execute-many is the ideal model here; never re-enter RW.

## 7. Prior art and upstream fix history

Precedents:

- **World of Padman** (May 2026) — the only independent ioq3-contract aarch64 JIT: a
  fresh ~1145-line port of the same SUSE vm_armv7l.c we ship, zero vm.c changes,
  merged as PR #402. Its four same-week bugfixes are the pitfall list for any
  armv7l-style port: entry branch must be `BL` not `B` (`fbeaa34026`); float compare
  conditions LT/LE → MI/LS for NaN (`5460fc4008`); variable-length `emit_MOVXi`
  breaking a hardcoded branch-skip count (`d13ce163ee`); argument registers (X0-X7)
  clobbered by VM execution — host pointers needed in the epilogue must live in
  callee-saved regs (`0a133a59b1`). This is our plan-B donor (GPL2+, drop-in
  signatures).
- **threecore** — lifted a 2020-2021 Quake3e vm_aarch64.c plus Quake3e's VM helpers
  into an ioq3-style tree; proves the strategy-(a) graft works.
- **ET:Legacy is not a precedent** — it deleted all QVM JITs in 2012 and runs mods as
  native libs; zero aarch64 JIT work exists there.
- **ioquake3 upstream has no aarch64 JIT** (PR #128 was interpreter-only; even
  vm_armv7l isn't default-on, issue #291).
- **Android specifically: nobody has shipped one.** Diii4a (Q3/RTCW/UrT mega-port) and
  ioq3quest both ship only vm_armv7l + interpreter on arm64. We'd be first; there is
  no platform blocker (§6), just no precedent to crib Android-specific fixes from.

Quake3e fix history relevant to our snapshot — **our snapshot is master HEAD at/after
2026-05-19 (`c84ea98`), so all of these are already included**; they matter as the
catalogue of bug classes not to reintroduce while adapting:

- `85ff550` (2021) NaN float compares: OP_LTF→MI, OP_LEF→LS after FCMP. Same bug hit
  independently by WoP five years later.
- `c84ea98` (2026) two-pass size determinism: pass-variant pointer materialization
  must be fixed-size (`emit_MOVXi64`). Any prologue change we make must preserve
  identical pass-0/pass-1 layout.
- `c0b1108` (2026) B.cond ±1MB range avoidance via `emitFuncBranches` islands.
  Measured against real EF QVMs: largest proc 3875 instructions → worst-case ~186 KB
  native, >5x margin (conditional branches are intra-proc only). Caveat:
  `encode_offset19` overflow is a hard Com_Error mid-compile (:1008-1017), not a
  fallback — can't trigger with known EF QVMs, but a giant mod QVM theoretically
  could.
- `36931ac` + `5f9279e`: every data access either masks or range-checks; the RCONST
  const-cache interaction with forceDataMask was the subtle one.
- `b6fabcf`/`63b03d7`/`f3c7c3e`: const-cache/register-allocator bugs — historically
  the most bug-prone area; CONST_CACHE_RX was once disabled outright. First toggle to
  flip when bisecting misbehavior.
- `c81078`: programStack is signed (zero-crossing).
- `7a35b5f`: pin AAPCS64 argument registers (S0) when calling out to sinf/cosf —
  don't let the dynamic allocator pick.
- ioq3 issue #570: NaN propagation in *gamecode* behaves differently at native speed —
  if EF gamecode misbehaves under the JIT but not the interpreter, suspect
  float-strictness in the QVM, not the JIT, before bisecting codegen.

Licensing: donor is GPLv2-or-later (id + Quake3e headers), lilium-voyager is
GPLv2-or-later — compatible. Keep all copyright lines, add provenance. The repo's
no-AI-attribution rule for public commits is unaffected by GPL requirements.

## 8. Test plan

Retail-QVM validation is already closed: a host harness ran the verbatim
quake3e pre-pass (VM_LoadInstructions + VM_CheckInstructions) over all 16 EF QVMs on
this machine — retail pak0/1/2 cgame/qagame/ui from
a retail install's `BaseEF/`, the port's custom ui.qvm,
plus pak92 and cMod community sets. **All pass** with NULL jump tables
(`__noJTS` path) and exactDataLength semantics; zero warnings beyond the safe-stores
DPrintf. Max per-proc opStack 32 bytes (ceiling 120), max frame 32032 bytes (limit
0x10000). No interpreter-fallback risk from validation strictness.

Devices:

| Device | Notes |
|---|---|
| Mali-G78 phone (ARMv8.2) | Primary. The arm64 APK flips **both** the CPU path and the GPU driver binary — test interpreter-arm64 (step 1) before the JIT (step 6) to separate the variables. No BTI/PAC/MTE hardware, so it cannot catch branch-protection faults. |
| Adreno 740 handheld | arm64 switches to the 64-bit Adreno Vulkan ICD — re-verify the post-bloom/MSAA fixes and the `vk.qcomClearBug` driver-version gate under the 64-bit driver. |
| Adreno 530 device | Same 32→64-bit driver flip; retest corruption fixes. |


Test sequence per build: menu (ui.qvm) → start map (cgame+qagame) → bot match 10+
min → map change → map_restart (VM_Restart: data reload, no recompile) →
vid_restart → demo playback comparison vs interpreter build.

Debugging:

- **vm_rtChecks is the first knob**: 15 = all checks (each failure is a labeled
  Com_Error: bad jump / out-of-range jump / program stack / op stack / data read /
  data write — instantly classifies the bug); 0 = forceDataMask mode (everything
  masked, no checks) — if 0 works and 15 drops, the bug is in check emission; if 15
  works and 0 crashes, a masked wild access is corrupting VM data.
- **SIGILL triage**: PC inside `[codeBase, codeBase+codeLength)` (compare against the
  tombstone maps) at a non-4-aligned-looking boundary or mid-emitted-region →
  two-pass layout drift (bug class `c84ea98`/WoP `d13ce163ee`) — diff pass-0 vs
  pass-1 `compiledOfs` per instruction. SIGILL at otherwise-valid code on first
  execution → cache-flush ordering (shouldn't happen with the §6 sequence).
- **SIGBUS/SIGSEGV triage**: fault address inside the data region + guard → guard
  sizing wrong (item 7 of §2); fault on the opStack local → canary/overflow (check
  the 0xDEADC0DE post-call assert fired first); fault at `instructionPointers` load →
  un-poisoned non-jused entry or jump-check elision.
- **Optimizer bisect**: the toggles at vm_aarch64.c:53-71 are independent defines —
  binary-search by disabling CONST_CACHE_RX/SX, then LOAD_OPTIMIZE, then
  CONST_OPTIMIZE. Matches the port's autoexec cvar-bisect workflow in spirit.
- **DUMP_CODE** (donor, optional define) writes the emitted code to a file via FS_* —
  usable on device for offline disassembly (`llvm-objdump -D -b binary -m aarch64`).
- **DEBUG_VM is unconditionally on** in the donor (:48) — extra compile-time DROPs +
  canary. Leave it on; the cost is negligible.

## 9. Open questions

- **Real-device perf delta unknown.** Quake3e claims ~40% VM-side gains over its own
  baseline; what matters here is JIT vs interpreter frame-time on the Mali phone
  path with the Vulkan renderer — unmeasured until step 8. (Interpreter arm64 might
  even be acceptable on big cores; the JIT could matter most on the handhelds.)
- **vm.c pre-pass interplay with VM_Restart**: quake3e frees its instruction buffers
  after compile; confirm the lifted block leaves nothing dangling across VM_Restart's
  no-recompile data reload (the donor's buffers are Z_Malloc'd and freed inside
  VM_Compile — believed clean, verify with a map_restart soak).
- **Float determinism interpreter↔JIT in netplay**: both use round-to-zero CVFI and
  IEEE single ops, but the interpreter goes through C `float` locals while the JIT
  uses scalar FPU directly — cross-play between a JIT client and interpreter/armv7
  server is believed consistent (same ISA semantics) but untested. Relevant for the
  mixed-device LAN case.
- **Adreno-handheld 64-bit driver behavior** is a renderer unknown stacked on this work: the
  Adreno corruption fixes were validated against the 32-bit ICD only. If the 64-bit
  driver misbehaves, it lands in this same release. Plan: validate step 1
  (interpreter arm64) on the Adreno handheld early, before the JIT exists, to decouple the bug
  surfaces.
- **Hardened-ROM coverage**: the interpreter fallback on execmem denial is designed
  but will be untested (no hardened-ROM device available).
- **Quad Touch precedent**: whether the commercial Quake3e Android port enables this
  JIT is unverifiable (no public source) — we may or may not be literally first, but
  must assume no prior Android field-testing of this codegen either way.

## 10. Sources

Upstream commits (github.com/ec-/Quake3e):
- `1310c3d9cd` 2020-08-30 — initial aarch64 compiler.
- `b6fabcf` 2020-11-27 — CONST_CACHE_RX disabled ("seems a bit buggy");
  `63b03d7` 2020-12-02 — cached-register selection fix; `f3c7c3e` 2022-10-23 —
  alloc_rx/alloc_sx bounds guards.
- `85ff5501b7` 2021-05-25 — NaN float-compare fix (MI/LS).
  https://github.com/ec-/Quake3e/commit/85ff5501b7
- `7a35b5f` 2021-06-02 — explicit ABI argument registers.
- `36931ac` 2021-10-14 — always mask or range-check data; `5f9279e` 2026-04-12 —
  RCONST + forceDataMask fix.
- `c81078321c` — programStack signedness.
- `a2eae08dd3` 2026-03-11 — vm_optimize.h split; `65560d7` 2026-04-02 — DYN_ALLOC
  typo + empty-proc proc_base fix.
- `c0b1108f2d` 2026-04-13 — long-conditional-branch avoidance.
  https://github.com/ec-/Quake3e/commit/c0b1108f2d
- `c84ea9898a` 2026-05-19 — emit_MOVXi64 two-pass sizing fix (PR #400, issue #399).
  https://github.com/ec-/Quake3e/issues/399 · https://github.com/ec-/Quake3e/pull/400
- Snapshot fingerprint: local quake3e-ref vm_aarch64.c/vm.c/vm_local.h/vm_optimize.h
  byte-identical to master (verified 2026-06-07 via raw.githubusercontent.com).

World of Padman (github.com/PadWorld-Entertainment/worldofpadman):
- Issue #382 (ARM64 request), PR #402 (merge), PR #407 (macOS enable).
- `b2439a6399` initial; fixes `fbeaa34026` (BL entry), `5460fc4008` (NaN conds),
  `d13ce163ee` (jump-validation skip count), `0a133a59b1` (X1 clobber → X26).

Other prior art:
- threecore (Quake3e-VM lift into ioq3-style tree): https://github.com/noire-dev/threecore
- ET:Legacy JIT deletion: https://github.com/etlegacy/etlegacy/commit/1c64682bb5
- ioq3 #291 (armv7l not default), #570 (gamecode NaN on ARM):
  https://github.com/ioquake/ioq3/issues/570
- Diii4a (no aarch64 JIT shipped): https://github.com/glKarin/com.n0n3m4.diii4a

Platform:
- AOSP sepolicy app.te (execmem):
  https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/main/private/app.te
- Arm, caches & self-modifying code:
  https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/caches-self-modifying-code-implementing-clear-cache
- compiler-rt clear_cache.c:
  https://github.com/llvm-mirror/compiler-rt/blob/master/lib/builtins/clear_cache.c
- LLVM D104094 (missing dsb fix): https://reviews.llvm.org/D104094
- Mono big.LITTLE icache bug: https://www.mono-project.com/news/2016/09/12/arm64-icache/
  · fix https://github.com/mono/mono/pull/3549
- arm64 BTI: https://lwn.net/Articles/802780/ · bionic PROT_BTI:
  https://github.com/aosp-mirror/platform_bionic/blob/master/linker/linker_phdr.cpp
- NDK branch-protection default-off: https://github.com/android/ndk/discussions/1706
  · https://github.com/android/ndk/issues/1479
- MTE: https://developer.android.com/ndk/guides/arm-mte
- 16 KB pages: https://developer.android.com/guide/practices/page-sizes ·
  https://source.android.com/docs/core/architecture/16kb-page-size/16kb ·
  https://android-developers.googleblog.com/2025/05/prepare-play-apps-for-devices-with-16kb-page-size.html
- Reference JITs: Dolphin Arm64Emitter.cpp (FlushIcacheSection), PPSSPP
  MemoryUtil.cpp + 16 KB PR #19658, mupen64plus-nx assem_arm64.c, Box64, ART JIT
  (dual-view, not needed here):
  https://source.android.com/docs/core/runtime/jit-compiler
- GrapheneOS execmem toggle:
  https://github.com/GrapheneOS/platform_system_sepolicy/blob/14/private/untrusted_app_all.te

Local anchors: donor `quake3e-ref/code/qcommon/vm_aarch64.c:792,1161-1223,1546,
2259-2333,2343-2388`, `vm_optimize.h`, q3e `vm.c:39-204,938-1642`, q3e
`vm_local.h:38-52,143-153,169-225,246-257`; target `efcode/qcommon/vm_local.h:141-193`,
`vm.c:366-522,576-687,748-762,807-873,997-1010`, `vm_armv7l.c:223-250,628,1156-1162,
1168-1222`; build `jni/src/CMakeLists.txt:31-40,95-115`, `app/build.gradle:14-25`,
`jni/CMakeLists.txt:7`, `build-native.sh:23`, `build-all.sh:13-16`.
