#!/usr/bin/env bash
# Build baseEF/vm/ui.qvm from the Elite Force GDK UI sources using the original
# Raven/id Windows toolchain (lcc.exe + q3asm.exe) via WSL interop. Mirrors
# Code-DM/ui/ui.bat + ui.q3asm. Needs the GDK tree (not part of this repo)
# checked out next to this directory as stvoy/.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
UI="$ROOT/stvoy/Code-DM/ui"
BIN="$ROOT/stvoy/bin_nt"
[ -d "$UI" ] || { echo "ERROR: GDK UI sources not found at $UI"; exit 1; }
# Raven's lcc.exe looks for cpp.exe/rcc.exe via the LCCDIR env var (its compiled-in
# default is c:\stvoy\Code-DM\lcc\bin). WSLENV forwards the var to Windows processes.
LCCDIR="$(wslpath -w "$ROOT/stvoy/Code-DM/lcc/bin")"
export LCCDIR
export WSLENV="LCCDIR:${WSLENV}"

cd "$UI"
rm -rf vm && mkdir vm
cd vm

CC=("$BIN/lcc.exe" -DQ3_VM -S -Wf-target=bytecode -Wf-g
    '-I..\..\cgame' '-I..\..\game' '-I..\..\ui')

# every module named in ui.q3asm (the authoritative list), minus ui_syscalls
# (that one links from the hand-written ui/ui_syscalls.asm)
SRC_UI=(ui_main ui_gameinfo ui_atoms ui_connect ui_controls2 ui_demo2 ui_fonts
        ui_mfield ui_menu ui_ingame ui_confirm ui_sound ui_network
        ui_playermodel ui_players ui_playersettings ui_preferences ui_qmenu
        ui_serverinfo ui_servers2 ui_sparena ui_specifyserver ui_sppostgame
        ui_splevel ui_spskill ui_startserver ui_team ui_video ui_addbots
        ui_removebots ui_teamorders ui_cdkey ui_mods ui_cvars)
SRC_GAME=(bg_misc bg_lib q_math q_shared)

for f in "${SRC_UI[@]}";   do echo "LCC $f"; "${CC[@]}" "..\\$f.c"; done
for f in "${SRC_GAME[@]}"; do echo "LCC $f"; "${CC[@]}" "..\\..\\game\\$f.c"; done

# q3asm list file: same module order as ui.q3asm but with a sane output path
cat > ui_android.q3asm <<'EOF'
-o "ui"
ui_main
..\ui_syscalls
ui_gameinfo
ui_atoms
ui_connect
ui_controls2
ui_demo2
ui_fonts
ui_mfield
ui_menu
ui_ingame
ui_confirm
ui_sound
ui_network
ui_playermodel
ui_players
ui_playersettings
ui_preferences
ui_qmenu
ui_serverinfo
ui_servers2
ui_sparena
ui_specifyserver
ui_sppostgame
ui_splevel
ui_spskill
ui_startserver
ui_team
ui_video
ui_addbots
ui_removebots
ui_teamorders
ui_cdkey
ui_mods
ui_cvars
bg_misc
bg_lib
q_math
q_shared
EOF

echo "Q3ASM ui.qvm"
"$BIN/q3asm.exe" -f ui_android -verbose | tail -5
ls -la ui.qvm
cp ui.qvm "$ROOT/android-port/ui.qvm"
echo "OK -> android-port/ui.qvm"
