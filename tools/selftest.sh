#!/bin/bash
# Offline selftest: compiles the non-UI code (Core, Mail, Net, plus the UI-free HTML sanitiser and outbox)
# with Tests/SelfTest.swift and runs it. No network, no Keychain, no UI; data goes to a throwaway folder.
set -euo pipefail
cd "$(dirname "$0")/.."

# What's under test (R-04): whole folders, so new files are picked up automatically.
TEST_DIRS=(Sources/Core Sources/Mail Sources/Net)
TEST_FILES=(Sources/UI/HTMLPrep.swift Sources/UI/InlineImages.swift Sources/Sync/Outbox.swift)

OUT="$(mktemp -d "${TMPDIR:-/tmp}/macmail-selftest.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

# Tests write only under here: the sandbox forbids NSTemporaryDirectory(), so point every test at $OUT.
export MAC_MAIL_SELFTEST_TMP="$OUT"

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "${TEST_DIRS[@]}" -name '*.swift' | sort)
SOURCES+=("${TEST_FILES[@]}")
cp Tests/SelfTest.swift "$OUT/main.swift"

# -Onone: this is a fast correctness gate, not a benchmark.
swiftc -swift-version 5 -Onone -module-cache-path "${MAC_MAIL_SELFTEST_CACHE:-$OUT/ModuleCache}" \
    "${SOURCES[@]}" "$OUT/main.swift" -o "$OUT/selftest"

MAC_MAIL_SUPPORT_DIR="$OUT/support" MAC_MAIL_CACHE_DIR="$OUT/caches" "$OUT/selftest"
