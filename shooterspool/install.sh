#!/usr/bin/env bash
# Install ShootersPool on Linux (Wine 11 + native Wayland, fullscreen)
#
# Usage: ./install.sh path/to/ShootersPool-1.10.4_Setup.exe
set -euo pipefail

SETUP_EXE="${1:?Usage: $0 path/to/ShootersPool-Setup.exe}"
SETUP_EXE="$(realpath "$SETUP_EXE")"
[ -f "$SETUP_EXE" ] || { echo "Not found: $SETUP_EXE"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$HOME/.local/share/shooterspool"
GAME_DIR="$PREFIX/drive_c/Program Files (x86)/ShootersPool"

info() { echo -e "\033[0;32m[+]\033[0m $*"; }
fail() { echo -e "\033[0;31m[x]\033[0m $*"; exit 1; }

# ── Dependencies ──────────────────────────────────────────────────
if ! wine --version 2>/dev/null | grep -q "wine-1[1-9]"; then
    info "Installing Wine 11 from WineHQ..."
    sudo dpkg --add-architecture i386
    sudo mkdir -pm755 /etc/apt/keyrings
    sudo wget -qO /etc/apt/keyrings/winehq-archive.key \
        https://dl.winehq.org/wine-builds/winehq.key
    sudo wget -qNP /etc/apt/sources.list.d/ \
        https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources
    sudo apt update -qq
    sudo apt install -y --install-recommends winehq-stable
fi
dpkg -s libegl1:i386 &>/dev/null || {
    info "Installing 32-bit EGL..."
    sudo apt install -y libegl1:i386
}
which winetricks &>/dev/null || {
    info "Installing winetricks..."
    sudo apt install -y winetricks
}
dpkg -s gcc-mingw-w64-i686 &>/dev/null || {
    info "Installing MinGW cross-compiler..."
    sudo apt install -y gcc-mingw-w64-i686
}
info "Wine: $(wine --version)"

# ── Clean prefix ──────────────────────────────────────────────────
WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null || true
[ -d "$PREFIX" ] && rm -rf "$PREFIX"

info "Creating Wine prefix..."
env -u DISPLAY -u WAYLAND_DISPLAY WINEPREFIX="$PREFIX" wineboot -u 2>/dev/null
WINEPREFIX="$PREFIX" wineserver -w 2>/dev/null

# ── Core fonts (fixes CEF/Chromium dwrite crash) ──────────────────
info "Installing Windows core fonts..."
WINEPREFIX="$PREFIX" winetricks -q corefonts 2>/dev/null
WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null || true

# ── Install game (NSIS silent — headless) ─────────────────────────
info "Installing game (silent — takes a few minutes)..."
env -u DISPLAY -u WAYLAND_DISPLAY WINEPREFIX="$PREFIX" wine "$SETUP_EXE" /S 2>/dev/null
WINEPREFIX="$PREFIX" wineserver -w 2>/dev/null

[ -f "$GAME_DIR/bin/ShootersPool.exe" ] || fail "Installation failed"
info "Game installed at: $GAME_DIR"

# ── Fullscreen DLL (proxy version.dll) ────────────────────────────
info "Building fullscreen helper..."
i686-w64-mingw32-gcc -shared -O2 \
    -o "$GAME_DIR/bin/version.dll" \
    "$SCRIPT_DIR/fullscreen.c" \
    -Wl,--subsystem,windows,--kill-at
info "Fullscreen DLL installed"

# ── Registry (direct file write — no wineserver race) ────────────
info "Setting registry..."
TS=$(date +%s)

cat >> "$PREFIX/user.reg" << EOF

[Software\\\\ShootersPool] ${TS}
"WorkDir"="C:\\\\Program Files (x86)\\\\ShootersPool\\\\bin"
"gamepath"="C:\\\\Program Files (x86)\\\\ShootersPool"
"Install_Dir"="C:\\\\Program Files (x86)\\\\ShootersPool"
"InstallPath"="C:\\\\Program Files (x86)\\\\ShootersPool"
"Path"="C:\\\\Program Files (x86)\\\\ShootersPool"

[Software\\\\Wine\\\\Drivers] ${TS}
"Graphics"="wayland"

[Software\\\\Wine\\\\Wayland Driver] ${TS}
"Decorated"="N"

[Software\\\\Wine\\\\X11 Driver] ${TS}
"Decorated"="N"
EOF

info "Done. Run with: ./run.sh"
