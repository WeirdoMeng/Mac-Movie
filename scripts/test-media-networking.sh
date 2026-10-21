#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/mac-movie-clang-cache"
mkdir -p .build
CHECK_SOURCES=()
for SOURCE in Sources/MacMovie/*.swift; do
    if [[ "$SOURCE" != "Sources/MacMovie/MacMovie.swift" ]]; then CHECK_SOURCES+=("$SOURCE"); fi
done
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macosx13.0" -parse-as-library "${CHECK_SOURCES[@]}" Tests/MediaNetworking/main.swift -o .build/MediaNetworkingCheck
/usr/bin/python3 Tests/MediaNetworking/server.py "$PWD/.build/MediaNetworkingCheck"
