#!/usr/bin/env bash
# Build ArxivFeed.app (backend bundled inside) and wrap it in a drag-to-Applications DMG:
#   dist/ArxivFeed-<version>.dmg
# Needs only the Command Line Tools + python3 (a small venv with dmgbuild is created under macapp/build).
#
# Without a Developer ID the app is ad-hoc signed and the recipient must allow it once in
# System Settings → Privacy & Security. With an Apple Developer account, this removes that step:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<profile> ./package.sh
# (NOTARY_PROFILE = a keychain profile made with `xcrun notarytool store-credentials`.)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(sed -nE 's/^VERSION=([0-9.]+).*/\1/p' macapp/build.sh | head -1)"
[ -n "$VERSION" ] || { echo "cannot read VERSION from macapp/build.sh" >&2; exit 1; }

(cd macapp && ./build.sh)

TOOLS=macapp/build/dmgtools
if [ ! -x "$TOOLS/bin/dmgbuild" ]; then
    python3 -m venv "$TOOLS"
    "$TOOLS/bin/pip" install -q dmgbuild
fi

BG=macapp/build/dmg-bg.tiff
if [ ! -f "$BG" ] || [ macapp/Icon/make_dmg_bg.swift -nt "$BG" ]; then
    swiftc -O macapp/Icon/make_dmg_bg.swift -o macapp/build/make_dmg_bg
    macapp/build/make_dmg_bg macapp/build/dmg-bg.png macapp/build/dmg-bg@2x.png
    tiffutil -cathidpicheck macapp/build/dmg-bg.png macapp/build/dmg-bg@2x.png -out "$BG"
fi

mkdir -p dist
DMG="dist/ArxivFeed-$VERSION.dmg"
rm -f "$DMG"
"$TOOLS/bin/dmgbuild" -s packaging/dmg_settings.py \
    -D app=macapp/build/ArxivFeed.app -D bg="$BG" -D icon=macapp/build/AppIcon.icns \
    "ArxivFeed" "$DMG"
if [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi
echo "packaged $DMG ($(du -h "$DMG" | cut -f1))"
