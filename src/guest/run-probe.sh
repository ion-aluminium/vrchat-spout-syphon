#!/bin/bash
# run-probe.sh <exe> [args...] — run a Windows test exe under FEX + Proton's Wine with DXMT active.
#
# It mirrors the environment Steam gives VRChat (read from /proc/<VRChat.exe>/environ) and reuses the
# game's own prefix, so it shares the running wineserver and the same DXMT dlls. It never writes to the
# prefix or to Steam's files; it only starts one extra process.
set -u
S=$HOME/.local/share/Steam
P="$S/steamapps/common/Proton - Experimental/files"
export WINEPREFIX="$S/steamapps/compatdata/438100/pfx"
export STEAM_COMPAT_DATA_PATH="$S/steamapps/compatdata/438100"
export WINEDEBUG=${WINEDEBUG:--all}
export WINEDLLOVERRIDES="steam.exe=b;dotnetfx35.exe=b;dotnetfx35setup.exe=b;beclient.dll=b,n;beclient_x64.dll=b,n;winebth.sys=d;opencl=n,d;d3d11=n;d3d10core=n;d3d9=n;dxgi=n;d3d12=n;d3d12core=n"
export DISPLAY=:1
export XDG_RUNTIME_DIR=/run/user/1000
export ENABLE_GAMESCOPE_WSI=1 GAMESCOPE_WAYLAND_DISPLAY=/run/pressure-vessel/gamescope-socket
export LD_LIBRARY_PATH="$S/ubuntu12_64/video/:$P/lib/x86_64-linux-gnu:$P/lib/aarch64-linux-gnu:$P/lib/i386-linux-gnu"
export PATH="$P/bin:/usr/bin:/bin"
export FEX_ROOTFS=/usr/share/guestos/fex-mesa
export FEX_NEEDSSECCOMP=1 FEX_DISKCACHE=0
exec "$S/steamapps/common/FEX-Emu/usr/bin/FEX" "$P/bin/wine" "$@"
