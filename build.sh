#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="build/NotifyBar.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -target "$(uname -m)-apple-macosx12.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "${TMPDIR:-/tmp}/NotifyBar-module-cache" \
    Sources/*.swift -o "$APP/Contents/MacOS/NotifyBar"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/opencode.svg "$APP/Contents/Resources/opencode.svg"
cp Resources/terminal.png Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "$PWD/$APP"
