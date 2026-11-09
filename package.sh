#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP_NAME="Mac Mail"
BUILD_DIR="${MAC_MAIL_BUILD_DIR:-$HOME/Library/Caches/MacMailBuild}"
RELEASE_DIR="release"
APP="$BUILD_DIR/$APP_NAME.app"

./build.sh release

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO \
    "$RELEASE_DIR/MacMail-$VERSION.dmg" >/dev/null

touch "$RELEASE_DIR/.metadata_never_index"

echo "Packaged:"
ls -lh "$RELEASE_DIR"
