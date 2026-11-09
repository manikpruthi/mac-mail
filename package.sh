#!/bin/bash
# Release build → verified, versioned DMG in release/.
#   ./package.sh
# Environment:
#   MAC_MAIL_SIGN_IDENTITY   Developer ID identity (otherwise ad-hoc)
#   MAC_MAIL_NOTARY_PROFILE  notarytool keychain profile; when set, the DMG is notarised, stapled and verified
set -euo pipefail
cd "$(dirname "$0")"

# Notarisation needs a Developer ID signature: fail before the long build when the pair is incomplete.
if [ -n "${MAC_MAIL_NOTARY_PROFILE:-}" ]; then
    case "${MAC_MAIL_SIGN_IDENTITY:-}" in
        ""|-)
            echo "error: MAC_MAIL_NOTARY_PROFILE is set but MAC_MAIL_SIGN_IDENTITY is not a Developer ID identity" >&2
            exit 1
            ;;
    esac
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP_NAME="Mac Mail"
BUILD_DIR="${MAC_MAIL_BUILD_DIR:-$HOME/Library/Caches/MacMailBuild}"
RELEASE_DIR="release"
APP="$BUILD_DIR/$APP_NAME.app"

./build.sh release

BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$RELEASE_DIR/MacMail-$VERSION-$BUILD-universal.dmg"
mkdir -p "$RELEASE_DIR"
# Older releases are kept; only an artifact with this exact name is replaced (R-08).
rm -f "$DMG" "$DMG.sha256"

# Signature checks before packaging (R-09).
codesign --verify --deep --strict --verbose=1 "$APP"
if [ -n "${MAC_MAIL_SIGN_IDENTITY:-}" ]; then
    spctl --assess --type execute --verbose "$APP" || echo "warning: Gatekeeper assessment failed (not notarised yet?)"
else
    echo "note: ad-hoc signed — Gatekeeper will ask on first launch (see README → Install)"
fi

STAGE="$(mktemp -d)"
MOUNT="$(mktemp -d)"
trap 'hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; rm -rf "$STAGE" "$MOUNT"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
cp LICENSE "$STAGE/LICENSE.txt"
cp README.md "$STAGE/README.md"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# Smoke test: the image mounts and the app inside is intact and signed.
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
codesign --verify --strict "$MOUNT/$APP_NAME.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNT/$APP_NAME.app/Contents/Info.plist" >/dev/null
hdiutil detach "$MOUNT" -quiet

if [ -n "${MAC_MAIL_NOTARY_PROFILE:-}" ]; then
    # Notarisation only accepts a Developer ID Application signature (the pair was checked before the build).
    SIGNATURE="$(codesign --display --verbose=4 "$APP" 2>&1 || true)"
    case "$SIGNATURE" in
        *"Authority=Developer ID Application"*) ;;
        *) echo "error: MAC_MAIL_NOTARY_PROFILE needs a Developer ID Application signature" >&2; exit 1 ;;
    esac
    echo "Notarising $(basename "$DMG")…"
    xcrun notarytool submit "$DMG" --keychain-profile "$MAC_MAIL_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    # The ticket belongs to the image: validate it, then let Gatekeeper assess the app on the mounted image.
    xcrun stapler validate "$DMG"
    hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
    codesign --verify --strict "$MOUNT/$APP_NAME.app"
    spctl --assess --type execute --verbose=2 "$MOUNT/$APP_NAME.app"
    hdiutil detach "$MOUNT" -quiet
else
    echo "note: not notarised — set MAC_MAIL_NOTARY_PROFILE (with a Developer ID identity) to notarise and staple"
fi

(cd "$RELEASE_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
touch "$RELEASE_DIR/.metadata_never_index"

echo "Packaged:"
ls -lh "$DMG" "$DMG.sha256"
