#!/bin/bash
# Builds Mac Mail as a universal (arm64 + x86_64) app.
#   ./build.sh            debug build
#   ./build.sh release    optimised build (used by package.sh)
# Environment:
#   MAC_MAIL_BUILD_DIR      output folder (default ~/Library/Caches/MacMailBuild)
#   MAC_MAIL_ARCHS          "arm64" for faster local iteration (release requires both)
#   MAC_MAIL_SKIP_SELFTEST  skip the offline selftest
#   MAC_MAIL_SIGN_IDENTITY  a "Developer ID Application: …" identity (secure timestamp); ad-hoc signing otherwise
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacMail"
BUNDLE_NAME="Mac Mail"
BUILD_DIR="${MAC_MAIL_BUILD_DIR:-$HOME/Library/Caches/MacMailBuild}"
APP="$BUILD_DIR/$BUNDLE_NAME.app"
MODE="${1:-debug}"
read -r -a ARCHS <<< "${MAC_MAIL_ARCHS:-arm64 x86_64}"

SDK="$(xcrun --show-sdk-path)"
# One source of truth for the deployment target (R-10).
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"

if [ "$MODE" = "release" ] || [ "$MODE" = "--release" ]; then
    MODE="release"
    OPTIMIZATION=(-O -whole-module-optimization)
    if [ "${#ARCHS[@]}" -ne 2 ]; then
        echo "error: a release build must contain arm64 and x86_64 (unset MAC_MAIL_ARCHS)" >&2
        exit 1
    fi
else
    OPTIMIZATION=(-Onone -g)
fi

# Run the offline selftest before compiling (skip for fast local iteration).
if [ -z "${MAC_MAIL_SKIP_SELFTEST:-}" ]; then
    tools/selftest.sh
fi

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find Sources -name '*.swift' | sort)

# Build into a staging bundle; the installed/previous app is replaced only after everything succeeded (R-05).
mkdir -p "$BUILD_DIR"
STAGE="$(mktemp -d "$BUILD_DIR/stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
STAGED_APP="$STAGE/$BUNDLE_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

# Compile each architecture in parallel.
PIDS=()
BINARIES=()
for ARCH in "${ARCHS[@]}"; do
    OUT="$STAGE/$APP_NAME-$ARCH"
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
    echo "error: compilation failed; the previous build at $APP was left untouched" >&2
    exit 1
fi

lipo -create "${BINARIES[@]}" -output "$STAGED_APP/Contents/MacOS/$APP_NAME"
rm -rf "${BINARIES[@]}" "$STAGE"/*.dSYM

# Every requested slice must be present (R-06).
SLICES="$(lipo -archs "$STAGED_APP/Contents/MacOS/$APP_NAME")"
for ARCH in "${ARCHS[@]}"; do
    case " $SLICES " in
        *" $ARCH "*) ;;
        *) echo "error: binary is missing the $ARCH slice (has: $SLICES)" >&2; exit 1 ;;
    esac
done

cp Resources/Info.plist "$STAGED_APP/Contents/Info.plist"
# Build number = commit count, so every build is distinguishable (R-08). The source plist is not modified.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
if ! git diff --quiet HEAD 2>/dev/null; then BUILD_NUMBER="$((BUILD_NUMBER + 1))"; fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGED_APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$STAGED_APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"

# Hardened runtime, no App Sandbox (sandboxing would move the cache and Keychain items).
# Ad-hoc builds keep the default designated requirement (the code hash), so a Keychain grant belongs to
# exactly this binary and no timestamp is needed. A Developer ID identity gets the usual team-based
# requirement, a secure timestamp, and a check that both really landed (R-07, C-34).
IDENTITY="${MAC_MAIL_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    TIMESTAMP=(--timestamp=none)
else
    TIMESTAMP=(--timestamp)
fi
codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements Resources/MacMail.entitlements \
    --sign "$IDENTITY" "$STAGED_APP"
codesign --verify --strict "$STAGED_APP"
if [ "$IDENTITY" != "-" ]; then
    SIGNATURE="$(codesign --display --verbose=4 "$STAGED_APP" 2>&1 || true)"
    case "$SIGNATURE" in
        *"Timestamp="*) ;;
        *) echo "error: the Developer ID signature has no secure timestamp" >&2; exit 1 ;;
    esac
    case "$SIGNATURE" in
        *"flags="*runtime*) ;;
        *) echo "error: the Developer ID signature is missing the hardened runtime" >&2; exit 1 ;;
    esac
fi

rm -rf "$APP"
mv "$STAGED_APP" "$APP"
touch "$BUILD_DIR/.metadata_never_index"
echo "Built $APP (build $BUILD_NUMBER, $SLICES)"
