#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
sources=()
for source in Sources/NotchHub/*.swift; do
  if [[ "$source" != */EntryPoint.swift ]]; then sources+=("$source"); fi
done
swiftc -parse-as-library -swift-version 5 -module-cache-path "${TOUCH_MODULE_CACHE_PATH:-$PWD/.build/module-cache}" \
  "${sources[@]}" Tests/NotchHubTests/*.swift -o .build/checks/NotchHubChecks
.build/checks/NotchHubChecks
