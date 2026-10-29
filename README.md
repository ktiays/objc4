# objc4

An Android arm64 port of Apple's current public Objective-C runtime sources.
The upstream baseline is **objc4-951.1**, commit
`fb265098298302243cd7eeaa1f63f0ba7786dd9a` from
[apple-oss-distributions/objc4](https://github.com/apple-oss-distributions/objc4).
This fork develops on `main` and retains the Apple Xcode project.

The Android library uses the upstream class, selector, protocol, object lifetime,
weak reference, property, category, and exception implementations. It does not
use libobjc2 or the GNUstep runtime ABI. A separately pinned Swift BlocksRuntime
provides the language's Blocks support.

## Android quick start

Install CMake, Ninja, and Android NDK 29.0.14206865, then:

```sh
export ANDROID_NDK_ROOT=/path/to/android/ndk/29.0.14206865
./scripts/build-android.sh Debug
./scripts/test-android.sh Debug
./scripts/test-android.sh Release
```

The test script uses an already running arm64 device or emulator. Set
`ANDROID_SERIAL` when multiple devices are connected. Outputs are placed in
`build/android-arm64-Debug` or `build/android-arm64-Release`.

This is an experimental first port, with a correctness-first dispatcher and
deliberately conservative cache/image lifetimes. See
[Android architecture, integration, validation and limitations](docs/android.md)
before embedding it in an application.

## Keeping the upstream current

Apple code remains in `runtime/`; Android-specific implementations live in
`platform/android/`. Shared-source changes are guarded where their semantics
differ. Update from Apple's public source releases through the `upstream` remote,
and run the Android validation after resolving changes:

```sh
git fetch upstream
git merge upstream/main
```

The source version and the compiler's ABI selection are separate. The Android
build currently uses Clang's `-fobjc-runtime=macosx-26.0` metadata/code-generation
contract while targeting Android API 26; this does not target or require macOS.
Every Objective-C image in a process must use the same compatible runtime ABI.

## Licensing

Apple sources retain their original notices and [APPLE_LICENSE](APPLE_LICENSE).
The standalone BlocksRuntime has its own pinned provenance and license in
[`third-party/BlocksRuntime`](third-party/BlocksRuntime).
