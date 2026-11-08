#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacMail"
BUNDLE_NAME="Mac Mail"
BUILD_DIR="${MAC_MAIL_BUILD_DIR:-$HOME/Library/Caches/MacMailBuild}"
APP="$BUILD_DIR/$BUNDLE_NAME.app"
MODE="${1:-debug}"
# Both architectures by default; MAC_MAIL_ARCHS=arm64 speeds up local iteration.
read -r -a ARCHS <<< "${MAC_MAIL_ARCHS:-arm64 x86_64}"

SDK="$(xcrun --show-sdk-path)"
MIN_MACOS="14.0"

if [ "$MODE" = "release" ] || [ "$MODE" = "--release" ]; then
    OPTIMIZATION=(-O -whole-module-optimization)
    ARCHS=(arm64 x86_64)
else
    OPTIMIZATION=(-Onone -g)
fi

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources -name '*.swift' | sort)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Compile each architecture in parallel; a release must contain both.
PIDS=()
BINARIES=()
for ARCH in "${ARCHS[@]}"; do
    OUT="$BUILD_DIR/$APP_NAME-$ARCH"
    BINARIES+=("$OUT")
    echo "Compiling ${#SOURCES[@]} Swift files for $ARCH-apple-macos$MIN_MACOS ($MODE)…"
    swiftc -swift-version 5 -sdk "$SDK" -target "$ARCH-apple-macos$MIN_MACOS" "${OPTIMIZATION[@]}" \
        -module-name MacMail -module-cache-path "$BUILD_DIR/ModuleCache-$ARCH" \
        "${SOURCES[@]}" -o "$OUT" &
    PIDS+=($!)
done

FAILED=0
for PID in "${PIDS[@]}"; do
    wait "$PID" || FAILED=1
done
if [ "$FAILED" -ne 0 ]; then
    echo "error: compilation failed for at least one architecture" >&2
    exit 1
fi

lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
rm -rf "${BINARIES[@]}" "$BUILD_DIR"/*.dSYM

cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Pin the signature requirement to the bundle id so Keychain and notification grants survive rebuilds.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
codesign --force --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"

touch "$BUILD_DIR/.metadata_never_index"
echo "Built $APP"
lipo -info "$APP/Contents/MacOS/$APP_NAME"
