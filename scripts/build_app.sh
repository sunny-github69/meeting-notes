#!/bin/bash
# Builds build/MeetingNotes.app (ad-hoc signed). Requires Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/MeetingNotes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MeetingNotes "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP  ->  open $APP"
