#!/usr/bin/env bash
set -euo pipefail

objc_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
objc_configuration=${1:-Debug}
objc_threads=${2:-single}
case "$objc_configuration" in
    Debug|Release) ;;
    *) echo "Usage: $0 [Debug|Release] [single|threads]" >&2; exit 2 ;;
esac
case "$objc_threads" in
    single) objc_pthreads=OFF ;;
    threads) objc_pthreads=ON ;;
    *) echo "Usage: $0 [Debug|Release] [single|threads]" >&2; exit 2 ;;
esac
objc_toolchain=${OBJC_WASM_TOOLCHAIN_ROOT:-"$objc_root/build/wasm-toolchain"}
if ! python3 "$objc_root/scripts/prepare-wasm-toolchain.py" --root "$objc_toolchain" --check; then
    python3 "$objc_root/scripts/prepare-wasm-toolchain.py" --root "$objc_toolchain" \
        --jobs "${OBJC_BUILD_JOBS:-8}"
fi
source "$objc_toolchain/env.sh"
objc_build=${OBJC_WASM_BUILD_DIR:-"$objc_root/build/wasm-$objc_threads-$objc_configuration"}
emcmake cmake -S "$objc_root" -B "$objc_build" -G Ninja \
    -DCMAKE_BUILD_TYPE="$objc_configuration" -DOBJC_WASM_THREADS="$objc_pthreads"
cmake --build "$objc_build" --parallel "${OBJC_BUILD_JOBS:-8}"
