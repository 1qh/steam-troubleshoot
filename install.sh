#!/bin/bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SO_PATH="${SCRIPT_DIR}/steam_cef_gpu_fix.so"

STEAM_RT_ORIG="${HOME}/.steam/debian-installation/steamrt64/pv-runtime/steam-runtime-steamrt"
CUSTOM_RT="${HOME}/.steam/custom-steamrt"
ENTRY_POINT="${CUSTOM_RT}/_v2-entry-point"

# ── 1. Compile ──────────────────────────────────────────────────────
if [ ! -f "$SO_PATH" ]; then
    echo "Compiling steam_cef_gpu_fix.so ..."
    make -C "$SCRIPT_DIR"
fi

# ── 2. Set up custom Steam Runtime ─────────────────────────────────
# Symlink everything from the original runtime, then replace _v2-entry-point
if [ ! -d "$STEAM_RT_ORIG" ]; then
    echo "ERROR: Steam Runtime not found at $STEAM_RT_ORIG"
    echo "       Make sure Steam is installed first."
    exit 1
fi

echo "Setting up custom Steam Runtime at ${CUSTOM_RT} ..."
mkdir -p "$CUSTOM_RT"

# Symlink all files from original runtime (skip _v2-entry-point)
for f in "$STEAM_RT_ORIG"/*; do
    base="$(basename "$f")"
    [ "$base" = "_v2-entry-point" ] && continue
    ln -sfn "$f" "${CUSTOM_RT}/${base}"
done

# ── 3. Patch _v2-entry-point ────────────────────────────────────────
# Copy original and inject our LD_PRELOAD + flags
cp "$STEAM_RT_ORIG/_v2-entry-point" "$ENTRY_POINT"
chmod +x "$ENTRY_POINT"

# The original _v2-entry-point does:
#   line ~270: set -- -- "$@"
#   line ~275: if [ -n "${ld_preload}" ]; then ...
#   line ~280: exec "${here}/${run}" "$@"
# We inject AFTER the 'set -- -- "$@"' line to:
#   1. Append --no-sandbox --disable-seccomp-filter-sandbox to steamwebhelper args
#   2. Set ld_preload to include our .so (the original code picks it up at line ~275)
MARKER='# >>> steam-cef-gpu-fix >>>'
if ! grep -qF "$MARKER" "$ENTRY_POINT"; then
    # Find the 'set -- -- "$@"' line (the arg separator, near end of file)
    SET_LINE=$(grep -n 'set -- -- "\$@"' "$ENTRY_POINT" | tail -1 | cut -d: -f1)
    if [ -z "$SET_LINE" ]; then
        echo "ERROR: Could not find 'set -- -- \"\$@\"' line in _v2-entry-point"
        exit 1
    fi

    # Insert AFTER that line
    sed -i "${SET_LINE}a\\
${MARKER}\\
# Fix: intercept crashpad signal handlers + block clone3()\\
# https://github.com/ValveSoftware/steam-for-linux/issues/12942\\
case \"\$1\" in\\
    *steamwebhelper*)\\
        set -- \"\$@\" --no-sandbox --disable-seccomp-filter-sandbox\\
        ;;\\
esac\\
ld_preload=\"${SO_PATH}\${ld_preload:+:\$ld_preload}\"\\
# <<< steam-cef-gpu-fix <<<" "$ENTRY_POINT"

    echo "Patched _v2-entry-point"
else
    echo "_v2-entry-point already patched"
fi


# ── 4. Create launcher script ──────────────────────────────────────
LAUNCHER="${SCRIPT_DIR}/steam-fixed"
cat > "$LAUNCHER" << 'LAUNCHER_EOF'
#!/bin/bash
export STEAM_RUNTIME_STEAMRT="${HOME}/.steam/custom-steamrt"
exec steam "$@"
LAUNCHER_EOF
chmod +x "$LAUNCHER"

# ── 5. Create .desktop entry ──────────────────────────────────────
DESKTOP_DIR="${HOME}/.local/share/applications"
mkdir -p "$DESKTOP_DIR"
cat > "${DESKTOP_DIR}/steam-fixed.desktop" << EOF
[Desktop Entry]
Name=Steam (Fixed)
Comment=Steam with GPU fix for kernel 6.13+ / NVIDIA 580+/590+
Exec=env STEAM_RUNTIME_STEAMRT=${CUSTOM_RT} steam %U
Icon=steam
Terminal=false
Type=Application
Categories=Game;
MimeType=x-scheme-handler/steam;x-scheme-handler/steamlink;
EOF

echo ""
echo "Done! Launch Steam with:"
echo "  ${LAUNCHER}"
echo "  or use 'Steam (Fixed)' from your app menu."
