# EF tcGen environment ("chrome") texcoord formula — analysis

STATUS: analyzed, not yet implemented. The Vulkan renderer generates
environment-mapped ("chrome") texture coordinates with the Quake 3 formula in
both the CPU and GPU paths; Elite Force uses a different formula, so reflective
trim (weapon chrome, Borg conduits, shiny surfaces) pans/maps differently than
on desktop EF. This documents the root cause, the dual-path layout, the verified
fix, and the build-tool situation. Local design note; not part of the public
tree until the fix lands.

## Symptom

Every reflective/chrome surface samples its environment map at a different
position and pans in a different direction than desktop Elite Force. Cosmetic
but visible on most shiny trim.

## Root cause

The reference renderer keeps an EF-specific branch that the Vulkan port dropped.
`ELITEFORCE` is defined for this build (src/CMakeLists.txt:99).

renderergl1/tr_shade_calc.c:894 `RB_CalcEnvironmentTexCoords`:

    reflected[0] = normal[0]*2*d - viewer[0];
    reflected[1] = normal[1]*2*d - viewer[1];
    reflected[2] = normal[2]*2*d - viewer[2];
    #ifdef ELITEFORCE
        st[0] = reflected[0] * 0.5;   // X/Y reflected components, no 0.5 bias
        st[1] = reflected[1] * 0.5;
    #else
        st[0] = 0.5 + reflected[1] * 0.5;   // Q3: Y/Z components, 0.5 bias
        st[1] = 0.5 - reflected[2] * 0.5;
    #endif

renderervk/tr_shade_calc.c:1041 `RB_CalcEnvironmentTexCoords` has no ELITEFORCE
branch — it computes only reflected[1]/[2] (reflected[0] is commented out) and
always emits the Q3 form. So the three differences versus desktop EF are:

- EF uses the X and Y reflected components; the port uses Y and Z.
- EF applies no 0.5 bias; the port adds 0.5 to each coordinate.
- The component signs differ.

Note: the earlier backlog note quoted the EF formula as
`0.5 - reflected[1]*0.5 / 0.5 + reflected[2]*0.5`. That is the screenmap variant
(`RB_CalcEnvironmentTexCoordsFPscr`, renderervk/tr_shade_calc.c:960), NOT the
standard chrome formula. The authoritative reference is the renderergl1
ELITEFORCE branch above.

## Dual-path layout (why a CPU-only edit is incomplete)

Standard `tcGen environment` parses to `TCGEN_ENVIRONMENT_MAPPED`
(tr_shader.c:1029). `firstPerson` chrome parses to `TCGEN_ENVIRONMENT_MAPPED_FP`.

A single-bundle env stage with no texmods, not a depth fragment, on a generic
shader type, is PROMOTED to a GPU `*_ENV` shader at finish
(tr_shader.c:3582-3599): `def.shader_type++`, `TESS_ENV` set, and
`bundle[0].tcGen = TCGEN_BAD` so the CPU path is skipped. Therefore:

- Common world chrome -> GPU vertex shader (gen_vert.tmpl USE_ENV) -> Q3 formula.
  This is the most visible case.
- Stages that do not promote (texmods, multiple env bundles, depthFragment) ->
  CPU `RB_CalcEnvironmentTexCoords` (tr_shade.c:850) -> Q3 formula.
- First-person weapon chrome -> CPU `RB_CalcEnvironmentTexCoordsFP`
  (tr_shade.c:853), an intentional OpenArena-derived viewmodel effect.

Both the CPU function and the GPU shader must be corrected for a complete fix.

GPU formula today, gen_vert.tmpl:110-116:

    vec3 viewer = normalize(eyePos.xyz - in_position);
    float d = dot(in_normal, viewer);
    vec2 reflected = in_normal.yz * 2 * d - viewer.yz;
    frag_tex_coord0.s = 0.5 + reflected.x * 0.5;
    frag_tex_coord0.t = 0.5 - reflected.y * 0.5;

## Verified fix

### 1. CPU — renderervk/tr_shade_calc.c RB_CalcEnvironmentTexCoords (~1058)

    #ifdef ELITEFORCE
        reflected[0] = normal[0]*2*d - viewer[0];
        reflected[1] = normal[1]*2*d - viewer[1];
        st[0] = reflected[0] * 0.5;
        st[1] = reflected[1] * 0.5;
    #else
        reflected[1] = normal[1]*2*d - viewer[1];
        reflected[2] = normal[2]*2*d - viewer[2];
        st[0] = 0.5 + reflected[1] * 0.5;
        st[1] = 0.5 - reflected[2] * 0.5;
    #endif

### 2. GPU — shaders/gen_vert.tmpl USE_ENV block (~111)

    vec2 reflected = in_normal.xy * 2 * d - viewer.xy;
    frag_tex_coord0.s = reflected.x * 0.5;
    frag_tex_coord0.t = reflected.y * 0.5;

The GLSL is hardcoded to the EF form (this renderer is built EF-only). It could
instead be guarded behind a `-DELITEFORCE` define added to every USE_ENV line in
the compile script, mirroring the CPU #ifdef, if Q3 parity of the template ever
matters.

### 3. Regenerate the env SPIR-V in shaders/spirv/shader_data.c

The shipped shader_data.c is prebuilt. The single USE_ENV block in gen_vert.tmpl
feeds 18 compiled variants, one per `-DUSE_ENV` line in compile.bat, matched 1:1
by 18 `vert_*_env*` arrays in shader_data.c:

    vert_tx0_env            vert_tx0_env_fog
    vert_tx0_ident1_env     vert_tx0_ident1_env_fog
    vert_tx0_fixed_env      vert_tx0_fixed_env_fog
    vert_tx1_env            vert_tx1_env_fog
    vert_tx1_ident1_env     vert_tx1_ident1_env_fog
    vert_tx1_fixed_env      vert_tx1_fixed_env_fog
    vert_tx1_cl_env         vert_tx1_cl_env_fog
    vert_tx2_env            vert_tx2_env_fog
    vert_tx2_cl_env         vert_tx2_cl_env_fog

Only these 18 arrays need regenerating; the other ~100 shaders stay untouched,
keeping the diff minimal.

## Build-tool situation (the old blocker is gone)

compile.bat is Windows-only. The two tools it needs are both present on the
Linux/WSL box:

- glslangValidator 11:16.2.0 at /usr/bin/glslangValidator (the exact tool
  compile.bat invokes). Recompiling the current, unmodified gen_vert.tmpl with
  `-DUSE_ENV` reproduces the shipped `vert_tx0_env[2324]` array BYTE-FOR-BYTE,
  proving the toolchain matches the original author's.
- bin2hex (shaders/bin2hex.c) is a trivial formatter:
  `const unsigned char NAME[LEN] = {\n\t0xXX, ... (16/line) \n};\n`. No host C
  compiler is installed (gcc/clang absent from PATH), but the format is exactly
  reproducible in a few lines of Python, so building bin2hex is unnecessary.

Recommended follow-up artifact: a compile.sh that mirrors compile.bat for Linux
(none exists today), so future SPIR-V edits do not depend on Windows.

## Options

- A (recommended): edit CPU + GPU template, regenerate the 18 env arrays.
  Correct on every path. The SPIR-V-regen blocker that previously argued against
  this is resolved (tools verified, byte-exact).
- B (hotfix): gate off the promotion block (tr_shader.c:3591) under ELITEFORCE
  so all chrome runs on the CPU, then fix only the CPU formula; no SPIR-V regen.
  Permanently loses the GPU _ENV optimization (CPU texcoord work every frame on
  every chrome surface). No reason to choose this now.

## Scope and risk

- In scope: standard world chrome (TCGEN_ENVIRONMENT_MAPPED), both promoted-GPU
  and CPU. The CPU edit also corrects the non-first-person fallback inside
  RB_CalcEnvironmentTexCoordsFP.
- Out of scope (intentional EF/OpenArena behaviors): first-person weapon chrome
  (RB_CalcEnvironmentTexCoordsFP) and the mirror/portal screenmap variant
  (RB_CalcEnvironmentTexCoordsFPscr).
- Risk: low. The C and GLSL formulas are identical math and mirror the shipped
  renderergl1 reference; the regen toolchain is byte-verified. Acceptance check
  is visual: load a chrome-heavy scene (weapon chrome, Borg conduits) and confirm
  the pan direction/registration matches desktop EF.

## Key references

- renderervk/tr_shade_calc.c: RB_CalcEnvironmentTexCoords (1041),
  RB_CalcEnvironmentTexCoordsFP (991), RB_CalcEnvironmentTexCoordsFPscr (960)
- renderervk/tr_shade.c: R_ComputeTexCoords dispatch (850-854)
- renderervk/tr_shader.c: env tcGen parse (1029), promotion gate (3582-3599)
- renderergl1/tr_shade_calc.c: EF reference (894, ELITEFORCE branch ~915-921)
- renderervk/shaders/gen_vert.tmpl: GPU USE_ENV block (110-116)
- renderervk/shaders/compile.bat, bin2hex.c, spirv/shader_data.c
- ELITEFORCE define: src/CMakeLists.txt:99
