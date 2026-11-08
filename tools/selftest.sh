#!/bin/bash
# Compiles the protocol/MIME code with Tests/SelfTest.swift and runs the offline checks.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/macmail-selftest"
mkdir -p "$OUT"
cp Tests/SelfTest.swift "$OUT/main.swift"
swiftc -swift-version 5 -O -module-cache-path "$OUT/ModuleCache" \
    Sources/Mail/*.swift Sources/Net/*.swift Sources/Core/Models.swift "$OUT/main.swift" -o "$OUT/selftest"
"$OUT/selftest"
