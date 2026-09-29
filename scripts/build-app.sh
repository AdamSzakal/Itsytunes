#!/bin/sh
# Builds build/TinyPlayer.app (release).
# Signs ad-hoc by default. Ad-hoc builds look like a new app to the Keychain, so each rebuild asks
# again for the saved API key. Set SIGN_IDENTITY to a certificate name to keep one identity:
#   SIGN_IDENTITY="My Cert" ./scripts/build-app.sh
set -e
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
# Universal binary, so it runs on Apple Silicon and Intel Macs.
swift build -c release --arch arm64 --arch x86_64
APP=build/TinyPlayer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/apple/Products/Release/TinyPlayer "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TinyPlayer</string>
    <key>CFBundleIdentifier</key><string>local.tinyplayer</string>
    <key>CFBundleExecutable</key><string>TinyPlayer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
ditto -c -k --keepParent "$APP" build/TinyPlayer.zip
echo "Built $APP and build/TinyPlayer.zip"
