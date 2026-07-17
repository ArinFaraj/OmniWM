#!/usr/bin/env bash
# One-time cleanup for the stale Accessibility grant. Needed once after switching dev
# builds to a stable signing identity; not needed on every rebuild after that.
#
# Why: adhoc-signed builds got a new code hash every rebuild, so macOS silently stopped
# honoring the stored Accessibility grant while still showing the row as "enabled".
# Toggling the checkbox does not clear the stale requirement - only removing the row does.
# This removes it so you get one clean re-prompt against the new, stably-signed binary.
set -euo pipefail

BUNDLE_ID="com.barut.OmniWM"
APP="${1:-/Users/arinfaraj/OmniWM/dist/OmniWM.app}"

echo "Quitting OmniWM..."
osascript -e 'quit app "OmniWM"' 2>/dev/null || true
pkill -x OmniWM 2>/dev/null || true
sleep 1

echo "Clearing stale Accessibility grant for $BUNDLE_ID..."
tccutil reset Accessibility "$BUNDLE_ID"

echo "Relaunching $APP - click Allow when prompted (once)."
open "$APP"

echo
echo "Done. If a freeze ever happens again, from any terminal run: pkill -USR1 OmniWM"
echo "(unfreezes input without killing the app; pkill -9 OmniWM is the hard fallback)."
