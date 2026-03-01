#!/usr/bin/env bash
# Install ShootersPool on Linux (Wine 11 + native Wayland)
#
# Usage: ./install.sh path/to/ShootersPool-1.10.4_Setup.exe
set -euo pipefail

SETUP_EXE="${1:?Usage: $0 path/to/ShootersPool-Setup.exe}"
SETUP_EXE="$(realpath "$SETUP_EXE")"
[ -f "$SETUP_EXE" ] || { echo "Not found: $SETUP_EXE"; exit 1; }

PREFIX="$HOME/.local/share/shooterspool"
GAME_DIR="$PREFIX/drive_c/Program Files (x86)/ShootersPool"
OPENAL_URL="https://github.com/kcat/openal-soft/releases/download/1.24.2/openal-soft-1.24.2-bin.zip"

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
command -v 7z &>/dev/null || {
    info "Installing 7z..."
    sudo apt install -y p7zip-full
}
info "Wine: $(wine --version)"

# ── Clean prefix ──────────────────────────────────────────────────
WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null || true
[ -d "$PREFIX" ] && rm -rf "$PREFIX"

info "Creating Wine prefix..."
env -u DISPLAY -u WAYLAND_DISPLAY WINEPREFIX="$PREFIX" WINEDLLOVERRIDES="mscoree=d;mshtml=d" wineboot -u 2>/dev/null
WINEPREFIX="$PREFIX" wineserver -w 2>/dev/null

# ── Extract game (7z — skips running NSIS through Wine) ──────────
info "Extracting game files..."
mkdir -p "$GAME_DIR"
7z x -o"$GAME_DIR" "$SETUP_EXE" \
    -xr'!Products' -xr'!\$PLUGINSDIR' -xr'!*.nsis' -y >/dev/null

[ -f "$GAME_DIR/bin/ShootersPool.exe" ] || fail "Extraction failed"
info "Game extracted to: $GAME_DIR"

# ── OpenAL Soft ───────────────────────────────────────────────────
info "Installing OpenAL Soft..."
TMPD=$(mktemp -d)
wget -qO "$TMPD/openal.zip" "$OPENAL_URL"
unzip -qo "$TMPD/openal.zip" -d "$TMPD"
cp "$TMPD/openal-soft-1.24.2-bin/bin/Win32/soft_oal.dll" "$GAME_DIR/bin/"
cp "$GAME_DIR/bin/soft_oal.dll" "$GAME_DIR/bin/OpenAL32.dll"
cp "$GAME_DIR/bin/soft_oal.dll" "$PREFIX/drive_c/windows/syswow64/OpenAL32.dll"
rm -rf "$TMPD"

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
