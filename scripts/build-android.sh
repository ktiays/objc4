#!/usr/bin/env bash
set -euo pipefail

objc_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
objc_configuration=${1:-Debug}
case "$objc_configuration" in
    Debug|Release) ;;
    *) echo "Usage: $0 [Debug|Release]" >&2; exit 2 ;;
esac

objc_sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-"$HOME/Library/Android/sdk"}}
objc_ndk=${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-"$objc_sdk/ndk/29.0.14206865"}}
if [[ ! -f "$objc_ndk/build/cmake/android.toolchain.cmake" ]]; then
    echo "Set ANDROID_NDK_ROOT to an installed Android NDK (validated with 29.0.14206865)." >&2
    exit 1
fi
objc_build=${OBJC_ANDROID_BUILD_DIR:-"$objc_root/build/android-arm64-$objc_configuration"}
cmake -S "$objc_root" -B "$objc_build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$objc_ndk/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
    -DANDROID_STL=c++_shared -DCMAKE_BUILD_TYPE="$objc_configuration"
cmake --build "$objc_build" --parallel "${OBJC_BUILD_JOBS:-4}"
