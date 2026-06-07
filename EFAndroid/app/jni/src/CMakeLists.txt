cmake_minimum_required(VERSION 3.6)
project(efmain C)

# ---------------------------------------------------------------------------
# Elite Force (lilium-voyager) engine -> libmain.so for Android (SDL2 harness)
# Single-binary build: interpreted VM (NO_VM_COMPILED), renderergl2 statically
# linked (no USE_RENDERER_DLOPEN), SDL audio (no OpenAL), no curl/ogg/opus/mp3.
# ---------------------------------------------------------------------------

set(EF ${CMAKE_CURRENT_SOURCE_DIR}/../efcode)

# ---- engine source groups (mirrors Makefile.nx SOURCEFILES, minus _nx/codecs) ----
set(CLIENT_SRC
  ${EF}/client/cl_cgame.c   ${EF}/client/cl_cin.c     ${EF}/client/cl_console.c
  ${EF}/client/cl_input.c   ${EF}/client/cl_keys.c    ${EF}/client/cl_main.c
  ${EF}/client/cl_net_chan.c ${EF}/client/cl_parse.c  ${EF}/client/cl_scrn.c
  ${EF}/client/cl_ui.c      ${EF}/client/cl_avi.c
  ${EF}/client/snd_adpcm.c  ${EF}/client/snd_dma.c    ${EF}/client/snd_mem.c
  ${EF}/client/snd_mix.c    ${EF}/client/snd_wavelet.c
  ${EF}/client/snd_main.c   ${EF}/client/snd_codec.c  ${EF}/client/snd_codec_wav.c
  ${EF}/client/qal.c        ${EF}/client/snd_openal.c)

set(QCOMMON_SRC
  ${EF}/qcommon/cm_load.c   ${EF}/qcommon/cm_patch.c  ${EF}/qcommon/cm_polylib.c
  ${EF}/qcommon/cm_test.c   ${EF}/qcommon/cm_trace.c
  ${EF}/qcommon/cmd.c       ${EF}/qcommon/common.c    ${EF}/qcommon/cvar.c
  ${EF}/qcommon/files.c     ${EF}/qcommon/md4.c       ${EF}/qcommon/md5.c
  ${EF}/qcommon/msg.c       ${EF}/qcommon/net_chan.c  ${EF}/qcommon/net_ip.c
  ${EF}/qcommon/huffman.c   ${EF}/qcommon/q_math.c    ${EF}/qcommon/q_shared.c
  ${EF}/qcommon/unzip.c     ${EF}/qcommon/ioapi.c     ${EF}/qcommon/puff.c
  ${EF}/qcommon/vm.c        ${EF}/qcommon/vm_interpreted.c)

# VM execution: armv7 has a proven JIT recompiler (vm_armv7l.c) — native speed,
# fixes the interpreter-bound stutter. arm64 has no JIT here -> interpreter.
if(CMAKE_ANDROID_ARCH_ABI STREQUAL "armeabi-v7a")
  list(APPEND QCOMMON_SRC ${EF}/qcommon/vm_armv7l.c)
  set(EF_VM_JIT TRUE)
else()
  set(EF_VM_JIT FALSE)
endif()

set(SERVER_SRC
  ${EF}/server/sv_bot.c     ${EF}/server/sv_ccmds.c   ${EF}/server/sv_client.c
  ${EF}/server/sv_game.c    ${EF}/server/sv_init.c    ${EF}/server/sv_main.c
  ${EF}/server/sv_net_chan.c ${EF}/server/sv_snapshot.c ${EF}/server/sv_world.c)

file(GLOB BOTLIB_SRC ${EF}/botlib/*.c)

set(SDL_SRC
  ${EF}/sdl/sdl_input.c ${EF}/sdl/sdl_snd.c ${EF}/sdl/sdl_gamma.c ${EF}/sdl/sdl_glimp.c)

set(SYS_SRC
  ${EF}/sys/con_log.c ${EF}/sys/con_passive.c ${EF}/sys/sys_autoupdater.c ${EF}/sys/sys_unix.c)
# sys_main.c compiled separately so we can rename main -> SDL_main
set(SYS_MAIN ${EF}/sys/sys_main.c)

# ---- renderer (statically linked). EF_RENDERER = gl2 (default, proven) | vulkan (Quake3e renderervk
#      port — kills Mali pipeline-revalidation panning stutter). ----
if(NOT DEFINED EF_RENDERER)
  set(EF_RENDERER "gl2")
endif()
file(GLOB RENDERCOMMON_SRC ${EF}/renderercommon/*.c)
if(EF_RENDERER STREQUAL "vulkan")
  file(GLOB RENDERER_SRC ${EF}/renderervk/*.c)
  # tr_subs.c (standalone-DLL shims) excluded — statically linked
  list(REMOVE_ITEM RENDERER_SRC ${EF}/renderervk/tr_subs.c)
  # shader_data.c (prebuilt SPIR-V) is #included by vk.c — must NOT compile separately
  list(REMOVE_ITEM RENDERER_SRC ${EF}/renderervk/shaders/spirv/shader_data.c)
  set(GLSL_SRC "")
  set(EF_USE_VULKAN TRUE)
else()
  file(GLOB RENDERER_SRC ${EF}/renderergl2/*.c)
  list(REMOVE_ITEM RENDERER_SRC ${EF}/renderergl2/tr_subs.c)
  file(GLOB GLSL_SRC ${EF}/renderergl2/glsl/*.c)
  set(EF_USE_VULKAN FALSE)
endif()

# ---- bundled libs ----
file(GLOB ZLIB_SRC ${EF}/zlib/*.c)
file(GLOB JPEG_SRC ${EF}/jpeg-8c/*.c)

add_library(main SHARED
  ${CLIENT_SRC} ${QCOMMON_SRC} ${SERVER_SRC} ${BOTLIB_SRC}
  ${SDL_SRC} ${SYS_SRC} ${SYS_MAIN}
  ${RENDERER_SRC} ${RENDERCOMMON_SRC} ${GLSL_SRC}
  ${ZLIB_SRC} ${JPEG_SRC})

# Rename sys_main.c's main() to SDL_main() so SDLActivity's bootstrap calls it.
set_source_files_properties(${SYS_MAIN} PROPERTIES COMPILE_DEFINITIONS "main=SDL_main")

target_include_directories(main PRIVATE
  ${EF} ${EF}/zlib ${EF}/jpeg-8c ${EF}/AL
  ${CMAKE_CURRENT_SOURCE_DIR}/../SDL/include)

target_compile_definitions(main PRIVATE
  ELITEFORCE
  BOTLIB
  $<$<NOT:$<BOOL:${EF_VM_JIT}>>:NO_VM_COMPILED>
  $<$<BOOL:${EF_USE_VULKAN}>:USE_VULKAN>
  $<$<BOOL:${EF_USE_VULKAN}>:USE_VULKAN_API>
  USE_FLEXIBLE_DISPLAY=1
  USE_OPENAL USE_OPENAL_DLOPEN
  PRODUCT_VERSION="1.40"
  ARCH_STRING="${CMAKE_ANDROID_ARCH_ABI}"
  # Game data lives in the app's OBB directory (standard Android home for big
  # game data; accessible by the app without any storage permission).
  ANDROID_DATA_ROOT="/sdcard/Android/obb/com.voyager.ef"
  USE_LOCAL_HEADERS=1)

target_compile_options(main PRIVATE
  -fno-strict-aliasing -fvisibility=hidden -Wno-implicit-function-declaration
  # Always optimize the engine even in debug APKs: the bytecode INTERPRETER
  # (NO_VM_COMPILED runs cgame/qagame every frame), q_math and the renderer
  # backend are murderously slow at -O0, which is the panning-lag bottleneck.
  -O2 -fomit-frame-pointer)

find_library(GLES2_LIB GLESv2)
find_library(GLES3_LIB GLESv3)
find_library(LOG_LIB log)

target_link_libraries(main SDL2 ${GLES3_LIB} ${GLES2_LIB} EGL ${LOG_LIB} m)
