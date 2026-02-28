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

wine_env() {
    env -u DISPLAY \
        WINEPREFIX="$PREFIX" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
        "$@"
}

# ── Wine 11 ───────────────────────────────────────────────────────
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
info "Wine: $(wine --version)"

# ── 32-bit EGL ────────────────────────────────────────────────────
dpkg -s libegl1:i386 &>/dev/null || {
    info "Installing 32-bit EGL..."
    sudo apt install -y libegl1:i386
}

# ── Prefix + game install ─────────────────────────────────────────
if [ -d "$PREFIX" ]; then
    info "Removing old prefix..."
    rm -rf "$PREFIX"
fi

info "Creating Wine prefix..."
wine_env wineboot -u 2>/dev/null
wine_env wineserver -w 2>/dev/null

info "Installing game (silent — this takes a few minutes)..."
wine_env wine "$SETUP_EXE" /S 2>/dev/null
wine_env wineserver -w 2>/dev/null

[ -f "$GAME_DIR/bin/ShootersPool.exe" ] || fail "Installation failed"
info "Game installed at: $GAME_DIR"

# ── OpenAL Soft ───────────────────────────────────────────────────
info "Installing OpenAL Soft..."
TMPD=$(mktemp -d)
wget -qO "$TMPD/openal.zip" "$OPENAL_URL"
unzip -qo "$TMPD/openal.zip" -d "$TMPD"
cp "$TMPD/openal-soft-1.24.2-bin/bin/Win32/soft_oal.dll" "$GAME_DIR/bin/"
cp "$GAME_DIR/bin/soft_oal.dll" "$GAME_DIR/bin/OpenAL32.dll"
mkdir -p "$PREFIX/drive_c/windows/syswow64"
cp "$GAME_DIR/bin/soft_oal.dll" "$PREFIX/drive_c/windows/syswow64/OpenAL32.dll"
rm -rf "$TMPD"

# ── Registry ──────────────────────────────────────────────────────
# Write all registry entries directly to user.reg.
# This is done AFTER wineserver has exited (wineserver -w above)
# so there is no race between in-memory cache and on-disk file.
info "Setting registry..."

GAME_PATH='C:\\Program Files (x86)\\ShootersPool'
TIMESTAMP=$(date +%s)

# Append all sections at once to avoid wineserver race
cat >> "$PREFIX/user.reg" << EOF

[Software\\\\ShootersPool] ${TIMESTAMP}
#time=$(printf '%016x' $((TIMESTAMP * 10000000 + 116444736000000000)))
"WorkDir"="C:\\\\Program Files (x86)\\\\ShootersPool\\\\bin"
"gamepath"="C:\\\\Program Files (x86)\\\\ShootersPool"
"Install_Dir"="C:\\\\Program Files (x86)\\\\ShootersPool"
"InstallPath"="C:\\\\Program Files (x86)\\\\ShootersPool"
"Path"="C:\\\\Program Files (x86)\\\\ShootersPool"

[Software\\\\Wine\\\\Drivers] ${TIMESTAMP}
#time=$(printf '%016x' $((TIMESTAMP * 10000000 + 116444736000000000)))
"Graphics"="wayland"

[Software\\\\Wine\\\\Wayland Driver] ${TIMESTAMP}
#time=$(printf '%016x' $((TIMESTAMP * 10000000 + 116444736000000000)))
"Decorated"="N"

[Software\\\\Wine\\\\X11 Driver] ${TIMESTAMP}
#time=$(printf '%016x' $((TIMESTAMP * 10000000 + 116444736000000000)))
"Decorated"="N"
EOF

info "Done. Run with: ./run.sh \"ShootersPool Online.exe\""
