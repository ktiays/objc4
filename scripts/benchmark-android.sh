#!/usr/bin/env bash
set -euo pipefail

objc_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
objc_iterations=${1:-1000000}
if [[ ! "$objc_iterations" =~ ^[0-9]+$ ]]; then echo "Expected an iteration count." >&2; exit 2; fi
objc_adb=${ADB:-adb}
OBJC_ANDROID_CACHE_FASTPATH=ON "$objc_root/scripts/test-android.sh" Release
"$objc_adb" shell "LD_LIBRARY_PATH=/data/local/tmp/objc4-android /data/local/tmp/objc4-android/objc4-android-benchmark $objc_iterations"

objc_slow_build="$objc_root/build/android-arm64-Release-slow"
OBJC_ANDROID_BUILD_DIR="$objc_slow_build" OBJC_ANDROID_CACHE_FASTPATH=OFF \
    "$objc_root/scripts/build-android.sh" Release
objc_slow_remote=/data/local/tmp/objc4-android-slow
"$objc_adb" shell "mkdir -p $objc_slow_remote; cp /data/local/tmp/objc4-android/libc++_shared.so $objc_slow_remote/"
"$objc_adb" push "$objc_slow_build/libobjc4.so" "$objc_slow_build/objc4-android-benchmark" "$objc_slow_remote/"
"$objc_adb" shell "LD_LIBRARY_PATH=$objc_slow_remote $objc_slow_remote/objc4-android-benchmark $objc_iterations"
