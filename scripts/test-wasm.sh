#!/usr/bin/env bash
set -euo pipefail

objc_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
objc_configuration=${1:-Debug}
objc_threads=${2:-single}
objc_arch=${3:-wasm32}
"$objc_root/scripts/build-wasm.sh" "$objc_configuration" "$objc_threads" "$objc_arch"
case "$objc_arch" in
    wasm64) objc_build_prefix=wasm64 ;;
    *) objc_build_prefix=wasm ;;
esac
objc_build=${OBJC_WASM_BUILD_DIR:-"$objc_root/build/$objc_build_prefix-$objc_threads-$objc_configuration"}
ctest --test-dir "$objc_build" --output-on-failure
