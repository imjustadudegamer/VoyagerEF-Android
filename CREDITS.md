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
- **ZTM** — *Flexible Display* (widescreen / aspect handling) in lilium-voyager, used here for the
  device-agnostic screen fill.
- **faithvoid** — *VoyagerNX* (Nintendo Switch port); identified the ARM64 + EGL/GLES + touch/gyro path
  that informed this port. <https://github.com/faithvoid/VoyagerNX>
- **Daggolin** — *Tulip Voyager* (the lilium fork VoyagerNX is based on).
- **Noah Metzger (mo-/cMod)** — *cMod for Elite Force*; the game-data distribution used for testing.

## Libraries
- **SDL2** (libsdl.org) — the Android harness (SDLActivity, GLES context, input, audio). zlib license.
- zlib, libjpeg, and the other bundled libraries shipped with ioquake3.

## This Android port
- Build/integration work (NDK/CMake harness, Android storage + GLES + landscape + gamepad wiring,
  16 KB alignment, packaging) done in this repo. The EF logo icon is extracted from the game's own
  `menu/endcredits/ef_logo.tga` and remains © Raven/Paramount — used here for a fan port only.

This is a non-commercial fan port. No game assets are included or redistributed.
