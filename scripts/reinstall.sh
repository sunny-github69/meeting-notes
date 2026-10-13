#!/bin/bash
# Quits MeetingNotes, clears its macOS permissions, rebuilds, installs to /Applications and opens it.
# Use when macOS keeps asking for Screen Recording / Microphone after a rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x MeetingNotes 2>/dev/null || true
tccutil reset ScreenCapture com.local.meetingnotes || true
tccutil reset Microphone com.local.meetingnotes || true
./scripts/build_app.sh
rm -rf /Applications/MeetingNotes.app
cp -R build/MeetingNotes.app /Applications/
open /Applications/MeetingNotes.app
echo "Opened. Press Start recording and allow Microphone and Screen & System Audio Recording once."
