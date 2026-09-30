#!/bin/sh
# Builds "build/Itsytunes.app" and build/Itsytunes.zip (release).
# Signs ad-hoc by default. Ad-hoc builds look like a new app to the Keychain, so each rebuild asks
# again for the saved API key. Set SIGN_IDENTITY to a certificate name to keep one identity:
#   SIGN_IDENTITY="My Cert" ./scripts/build-app.sh
set -e
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.2.2}"
# Universal binary, so it runs on Apple Silicon and Intel Macs. Optimized for size, unused code dropped.
swift build -c release --arch arm64 --arch x86_64 -Xswiftc -Osize -Xlinker -dead_strip
APP="build/Itsytunes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/Itsytunes "$APP/Contents/MacOS/"
strip -x "$APP/Contents/MacOS/Itsytunes" # debug symbols: more than half the binary (before signing)
cp Resources/AppIcon.icns "$APP/Contents/Resources/" # made by scripts/make-icon.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Itsytunes</string>
    <key>CFBundleDisplayName</key><string>Itsytunes</string>
    <key>CFBundleIdentifier</key><string>local.tinyplayer</string> <!-- old name: keeps settings -->
    <key>CFBundleExecutable</key><string>Itsytunes</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
rm -f build/Itsytunes.zip
ditto -c -k --keepParent "$APP" build/Itsytunes.zip
echo "Built $APP and build/Itsytunes.zip"
