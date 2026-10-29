#!/usr/bin/env bash
set -euo pipefail

objc_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
objc_configuration=${1:-Debug}
"$objc_root/scripts/build-android.sh" "$objc_configuration"
objc_build=${OBJC_ANDROID_BUILD_DIR:-"$objc_root/build/android-arm64-$objc_configuration"}
objc_sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-"$HOME/Library/Android/sdk"}}
objc_ndk=${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-"$objc_sdk/ndk/29.0.14206865"}}
objc_adb=${ADB:-adb}
objc_device_abi=$("$objc_adb" shell getprop ro.product.cpu.abi | tr -d '\r')
if [[ "$objc_device_abi" != arm64-v8a ]]; then
    echo "An arm64-v8a Android device/emulator is required (found $objc_device_abi)." >&2
    exit 1
fi
objc_stl=()
for objc_candidate in "$objc_ndk"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so; do
    if [[ -f "$objc_candidate" ]]; then objc_stl=("$objc_candidate"); break; fi
done
if [[ ${#objc_stl[@]} -eq 0 ]]; then
    echo "Cannot locate the NDK's arm64 libc++_shared.so." >&2
    exit 1
fi
objc_remote=/data/local/tmp/objc4-android
"$objc_adb" shell "mkdir -p $objc_remote"
"$objc_adb" push "$objc_build/libobjc4.so" "$objc_build/libobjc4-test-plugin.so" \
    "$objc_build/objc4-android-smoke" "$objc_build/objc4-android-cache" \
    "$objc_build/objc4-android-benchmark" "${objc_stl[0]}" "$objc_remote/"
"$objc_adb" shell "LD_LIBRARY_PATH=$objc_remote $objc_remote/objc4-android-smoke"
"$objc_adb" shell "LD_LIBRARY_PATH=$objc_remote $objc_remote/objc4-android-cache"
