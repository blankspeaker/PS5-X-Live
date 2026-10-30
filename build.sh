#!/bin/bash
# Builds "PS5 X Live.app" into build/, with the bundled FFmpeg + Streamlink runtime,
# ad-hoc signs every executable inside it, and zips it.
set -euo pipefail
cd "$(dirname "$0")"
[ -x build/runtime/bin/ffmpeg ] && [ -x build/runtime/bin/streamlink ] || scripts/build-runtime.sh

APP="build/PS5 X Live.app"
rm -rf "$APP" build/PS5-X-Live.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Apple silicon only.
xcrun swiftc -O -target arm64-apple-macos13.0 Sources/main.swift -o "$APP/Contents/MacOS/PS5XLive"

R="$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/ps5xlive-relay.sh Resources/ps5xlive-dns.py Resources/AppIcon.icns THIRD_PARTY_NOTICES.md LICENSE "$R/"
cp -R ThirdPartyLicenses "$R/ThirdPartyLicenses"
cp -R build/runtime "$R/runtime"
chmod 755 "$R/ps5xlive-relay.sh" "$R/ps5xlive-dns.py"
xattr -cr "$APP"

# Sign nested Mach-O files first (dylibs, extension modules, executables), then the app.
find "$R/runtime" -type f -print0 | while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q "Mach-O"; then codesign -s - --force --timestamp=none "$f" 2>/dev/null; fi
done
codesign -s - --force --deep --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
(cd build && ditto -c -k --norsrc --keepParent "PS5 X Live.app" PS5-X-Live.zip)
echo "built $APP ($(du -sh "$APP" | cut -f1)), build/PS5-X-Live.zip ($(du -h build/PS5-X-Live.zip | cut -f1))"
