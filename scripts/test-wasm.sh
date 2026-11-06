#!/usr/bin/env bash
set -euo pipefail

objc_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
objc_configuration=${1:-Debug}
objc_threads=${2:-single}
"$objc_root/scripts/build-wasm.sh" "$objc_configuration" "$objc_threads"
objc_build=${OBJC_WASM_BUILD_DIR:-"$objc_root/build/wasm-$objc_threads-$objc_configuration"}
ctest --test-dir "$objc_build" --output-on-failure
