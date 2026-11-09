#!/bin/bash
# Removes local build output and agent/worker state (R-19). Never touches source or the installed app.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build .delegate .selftest-attachment.tmp
echo "Cleaned build/ and .delegate/ (size now: $(du -sh . | cut -f1))"
