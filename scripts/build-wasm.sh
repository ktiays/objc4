#!/usr/bin/env bash
set -euo pipefail

objc_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
objc_configuration=${1:-Debug}
objc_threads=${2:-single}
objc_arch=${3:-wasm32}
objc_usage="Usage: $0 [Debug|Release] [single|threads] [wasm32|wasm64]"
case "$objc_configuration" in
    Debug|Release) ;;
    *) echo "$objc_usage" >&2; exit 2 ;;
esac
case "$objc_threads" in
    single) objc_pthreads=OFF ;;
    threads) objc_pthreads=ON ;;
    *) echo "$objc_usage" >&2; exit 2 ;;
esac
case "$objc_arch" in
    wasm32) objc_build_prefix=wasm; objc_arch_flags=() ;;
    wasm64)
        objc_build_prefix=wasm64
        objc_arch_flags=(-DCMAKE_C_FLAGS=-sMEMORY64=1 -DCMAKE_CXX_FLAGS=-sMEMORY64=1) ;;
    *) echo "$objc_usage" >&2; exit 2 ;;
esac
objc_toolchain=${OBJC_WASM_TOOLCHAIN_ROOT:-"$objc_root/build/wasm-toolchain"}
if ! python3 "$objc_root/scripts/prepare-wasm-toolchain.py" --root "$objc_toolchain" --check; then
    python3 "$objc_root/scripts/prepare-wasm-toolchain.py" --root "$objc_toolchain" \
        --jobs "${OBJC_BUILD_JOBS:-8}"
fi
source "$objc_toolchain/env.sh"
objc_build=${OBJC_WASM_BUILD_DIR:-"$objc_root/build/$objc_build_prefix-$objc_threads-$objc_configuration"}
emcmake cmake -S "$objc_root" -B "$objc_build" -G Ninja \
    -DCMAKE_BUILD_TYPE="$objc_configuration" -DOBJC_WASM_THREADS="$objc_pthreads" \
    ${objc_arch_flags[@]+"${objc_arch_flags[@]}"}
cmake --build "$objc_build" --parallel "${OBJC_BUILD_JOBS:-8}"
