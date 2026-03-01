#!/usr/bin/env bash
# Run ShootersPool in fullscreen on native Wayland
#
# Usage: ./run.sh [exe-name]
# Default: "ShootersPool Online.exe"
set -euo pipefail

EXE="${1:-ShootersPool Online.exe}"
PREFIX="$HOME/.local/share/shooterspool"
GAME_BIN="$PREFIX/drive_c/Program Files (x86)/ShootersPool/bin"

[ -f "$GAME_BIN/$EXE" ] || { echo "Not found: $GAME_BIN/$EXE"; exit 1; }

cleanup() {
    WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null || true
}
trap cleanup EXIT

# Wine services must be running before game starts
env -u DISPLAY WINEPREFIX="$PREFIX" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" wineboot -u 2>/dev/null
sleep 3

cd "$GAME_BIN"
exec env -u DISPLAY \
    WINEPREFIX="$PREFIX" \
    WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    WINEFSYNC=1 \
    WINEDLLOVERRIDES="version=n,b" \
    wine "$EXE"
