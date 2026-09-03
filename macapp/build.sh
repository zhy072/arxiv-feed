#!/usr/bin/env bash
# Build ArxivFeed.app without Xcode (Command Line Tools only).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=0.3.0
BUILD_NUMBER=3
# Ad-hoc by default. Set SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" for a real signature.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

mkdir -p build

# App icon: rendered by a small AppKit script, packed with iconutil (ships with macOS).
if [ ! -f build/AppIcon.icns ] || [ Icon/make_icon.swift -nt build/AppIcon.icns ]; then
  swiftc -O Icon/make_icon.swift -o build/make_icon
  rm -rf build/AppIcon.iconset
  build/make_icon build/AppIcon.iconset build/AppIcon-preview.png
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

swift build -c release

APP=build/ArxivFeed.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ArxivFeed "$APP/Contents/MacOS/ArxivFeed"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The backend ships inside the bundle; the app installs it under ~/Library/Application Support on first launch.
SERVER_DST="$APP/Contents/Resources/server"
mkdir -p "$SERVER_DST"
rsync -a --exclude '__pycache__' --exclude '*.pyc' ../server/app/ "$SERVER_DST/app/"
cp ../server/requirements.txt ../server/.env.example ../server/run_pipeline.py "$SERVER_DST/"
echo "$VERSION" > "$SERVER_DST/VERSION"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ArxivFeed</string>
    <key>CFBundleDisplayName</key><string>ArxivFeed</string>
    <key>CFBundleIdentifier</key><string>local.arxivfeed</string>
    <key>CFBundleExecutable</key><string>ArxivFeed</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
EOF

if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force -s - "$APP"
else
    codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP"
fi
touch "$APP" # nudge Finder/Dock to re-read the icon
echo "built $APP — run with: open $APP"
