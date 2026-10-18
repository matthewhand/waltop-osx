#!/bin/bash
# Launch the WALTOP userspace pressure shim and Krita in the correct order.
#
#   ./kritadraw.sh
#
# Order matters: waltopd must be running, and QT_MAC_TABLET_IGNORE_BUTTON_MAPPING
# must be set, BEFORE Krita starts. Launching from the Krita binary directly does
# not give it a proper app context and will appear not to work.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$DIR/tools/waltopd"

if [[ ! -x "$SHIM" ]]; then
    echo "waltopd not built; building (this takes a moment)..."
    ( cd "$DIR/tools" && swiftc -O -o waltopd waltopd.swift )
fi

echo "Stopping any running Krita and waltopd..."
pkill -x krita 2>/dev/null || true
pkill -x waltopd 2>/dev/null || true
sleep 1

echo "Starting waltopd (logs to $DIR/tools/waltopd.log)..."
( cd "$DIR/tools" && exec ./waltopd ) &
sleep 1

launchctl setenv QT_MAC_TABLET_IGNORE_BUTTON_MAPPING 1
open -a Krita

echo
echo "Krita started with the pressure shim running."
echo "Draw something. Pressure should vary stroke width."
echo
echo "To undo the environment variable later:"
echo "  launchctl unsetenv QT_MAC_TABLET_IGNORE_BUTTON_MAPPING"
echo "To stop the shim:"
echo "  pkill -x waltopd"
