#!/bin/bash
# Builds build/MeetingNotes.app. Requires Xcode command line tools.
#
# Signing: macOS remembers Screen Recording / Microphone permission by the app's signature. An ad-hoc
# signature changes on every build, so macOS asks again after each rebuild. If a code-signing
# certificate named "MeetingNotes Local" exists in your keychain (see README), it is used instead and
# permissions survive rebuilds. Override the name with CODESIGN_IDENTITY="…".
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/MeetingNotes.app
rm -rf "$APP"  # first, so a failed build can't leave an old app behind to be installed by mistake
swift build -c release
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MeetingNotes "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

IDENTITY="${CODESIGN_IDENTITY:-MeetingNotes Local}"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with \"$IDENTITY\": permissions will be kept across rebuilds."
else
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed: macOS will ask for permissions again after each rebuild (see README to avoid this)."
fi
echo "Built $APP  ->  open $APP"
