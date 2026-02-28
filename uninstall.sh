#!/bin/bash
set -eu

CUSTOM_RT="${HOME}/.steam/custom-steamrt"
DESKTOP="${HOME}/.local/share/applications/steam-fixed.desktop"

echo "Removing custom Steam Runtime ..."
rm -rf "$CUSTOM_RT"

echo "Removing desktop entry ..."
rm -f "$DESKTOP"

echo ""
echo "Done. Steam will use the default runtime on next launch."
echo "You can also 'make clean' to remove the compiled .so."
