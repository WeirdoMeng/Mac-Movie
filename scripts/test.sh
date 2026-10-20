#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/mac-movie-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/mac-movie-swift-cache"
swift build -c release --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security --manifest-cache local
.build/release/MacMovie --check
