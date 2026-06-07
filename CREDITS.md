# Credits — Voyager EF (Elite Force on Android)

This Android port stands entirely on the work of others. It is a build/integration
effort: the engine, game, and almost all the hard rendering/netcode are theirs. Please
keep these credits intact in any redistribution.

## The game
- **Raven Software** — *Star Trek: Voyager — Elite Force* (2000), original game & "Holomatch" multiplayer.
- **Ritual Entertainment** — *Elite Force* expansion pack content.
- **Activision / Paramount** — publisher / Star Trek license. Star Trek and all related marks
  are trademarks of Paramount/CBS. **Game data files are not redistributable** — each user must
  supply their own copy.

## The engine lineage (all GPLv2)
- **id Software** — *Quake III Arena* (id Tech 3), the engine Elite Force is built on. GPLv2 release (2005).
- **ioquake3 contributors** — the modern, maintained Quake III engine (SDL2, OpenAL, renderergl2, etc.)
  that everything below derives from. <https://github.com/ioquake/ioq3>
- **Thilo Schulz** — *ioEF*, the original ioquake3-based Elite Force engine. <https://github.com/thiloschulz/ioef>
- **Zack Middleton (zturtleman) & clover.moe** — *lilium-voyager*, the maintained EF fork used as the
  engine base for this port. <https://github.com/clover-moe/lilium-voyager>
- **Eugene C. & Quake3e contributors** — *Quake3e*, whose Vulkan renderer (`renderervk`) is the
  renderer of this port, and whose AArch64 QVM compiler (`vm_aarch64.c` + `vm_optimize.h`) is the
  64-bit JIT of this port. <https://github.com/ec-/Quake3e>
- **ZTM** — *Flexible Display* (widescreen / aspect handling) in lilium-voyager, used here for the
  device-agnostic screen fill.
- **faithvoid** — *VoyagerNX* (Nintendo Switch port); identified the ARM64 + EGL/GLES + touch/gyro path
  that informed this port. <https://github.com/faithvoid/VoyagerNX>
- **Daggolin** — *Tulip Voyager* (the lilium fork VoyagerNX is based on).

## Libraries
- **SDL2** (libsdl.org) — the Android harness (SDLActivity, window/surface, input, audio). zlib license.
- zlib, libjpeg, and the other bundled libraries shipped with ioquake3.

## This Android port
- Port work done in this repo: NDK/CMake/Gradle harness, renderervk integration with the EF
  engine, touch controls, gamepad wiring, Android storage + in-app data import, the rebuilt
  Android UI module, and packaging. The EF logo icon is extracted from the game's own
  `menu/endcredits/ef_logo.tga` and remains © Raven/Paramount — used here for a fan port only.

This is a non-commercial fan port. No game assets are included or redistributed.
