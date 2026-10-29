# Android arm64 port

## Scope

The initial target is Android `arm64-v8a`, API level 26 or newer. NDK 29 and
CMake/Ninja are the validated build tools. The library is named `libobjc4.so`.
Foundation, CoreFoundation, libdispatch, UIKit, and Swift's Objective-C
interoperability are outside this port's scope.

The runtime core is objc4-951.1. Android uses raw ISA pointers, side-table
reference counts, ordinary pthread TLS/locks, and the upstream method lookup
and initialization logic. Apple tagged pointers, pointer authentication,
shared-cache preoptimization, and return-address-based autorelease elision are
disabled. Bionic heap pointer tags remain enabled and are preserved.

## Building and embedding

`scripts/build-android.sh Debug` builds the runtime, native smoke executable,
and a dynamically loaded test image. `scripts/test-android.sh Debug` also runs
them through adb. Pass `Release` for the optimized configuration.

For CMake consumers, initialize Objective-C in the top-level CMake directory,
add this repository as a subdirectory, then call
`objc4_add_android_module(your_target)` on **every** executable or shared library
containing Objective-C code. Compile ARC clients with `-fobjc-arc`. The helper
selects the Apple ObjC ABI, enables Blocks, links objc4, installs an ELF startup
hook, and retains the metadata sections against linker garbage collection.
Use the same ABI/code-generation flags for all images. Linking a library alone
does not install its Objective-C metadata registration hook.

```cmake
project(MyAndroidProject LANGUAGES C CXX ASM)
include(path/to/objc4/platform/android/objc4-enable-languages.cmake)
set(OBJC_BUILD_ANDROID_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(path/to/objc4 objc4)
add_library(my_jni_library SHARED bridge.m)
set_target_properties(my_jni_library PROPERTIES LINKER_LANGUAGE CXX)
objc4_add_android_module(my_jni_library)
target_compile_options(my_jni_library PRIVATE -fobjc-arc)
```

Configure the parent project with the NDK toolchain, `arm64-v8a`, API 26 or
newer, and `ANDROID_STL=c++_shared`, as in the build script.

Package `libobjc4.so` and the matching NDK `libc++_shared.so` with the app. JNI
entry points can call Objective-C after image constructors finish. Threads
entering Objective-C need an autorelease pool around work that can autorelease.

## ELF image registration

Clang emits Apple ObjC metadata into ELF sections such as `objc_classlist`,
`objc_selrefs`, `objc_catlist`, and `objc_protolist`. A small per-image C hook
passes their linker-defined boundaries to the runtime. The existing objc4
image-reading algorithms then fix up selectors, register classes/protocols,
attach categories and execute `+load`.

The runtime uses normalized in-memory image descriptors rather than parsing
Mach-O headers. A few upstream private type/function spellings are retained
inside the adapter so the central class algorithms can remain close to Apple.
They do not imply an Android implementation of Mach or dyld.

ELF registration is serialized and reentrant for `+load`. Image/range records
are published as an append-only list. Registered shared objects are pinned
with `RTLD_NODELETE`; metadata and method pointers remain valid after callers
release their own `dlopen` handles.

## Dispatch and object lifetime

The AAPCS64 dispatcher probes the upstream method cache in assembly and
tail-calls a cached IMP without taking `runtimeLock`, creating a stack frame,
or saving argument registers. Cache misses save x0–x8 and v0–v7, ask upstream
objc4 to find/initialize/resolve the method, then restore the original arguments
and tail-call the IMP. It supports super dispatch and nil scalar/FP/HFA returns.
Large indirect results preserve x8. The cache layout, selector hash, and IMP
encoding have compile-time checks against the C++ implementation.

The Android synchronization mechanism is a table of 256 cache-line-aligned
reader/writer shards, selected from the class address. Readers increment a
shared count before accessing any buckets and decrement it before invoking an
IMP or entering the slow path. Writers close admission, drain existing readers,
then mutate entries or publish a new buckets/mask pair. After replacement,
the old array can be freed immediately; it never enters the Mach retirement
queue. `cache_getImp` uses the same protocol. Colliding classes share a shard,
but independent readers can still proceed concurrently.

This is a guarded fast path, not Apple's lock-free restartable-range mechanism.
Each hit performs two atomic read/modify/write operations, and a preempted reader
can delay a writer. A reader that sees a pending writer takes the ordinary slow
path. The protocol prevents retired-cache accumulation, but per-class active
caches and the upstream shared empty-cache arrays still consume memory. It does
not synchronize entire method executions or make image unloading safe.

Set `OBJC_ANDROID_CACHE_FASTPATH=OFF` in CMake (or the build script's environment)
to disable the assembly/C++ cache-hit paths for diagnostics. Safe cache retirement
remains enabled. `OBJC_DEBUG_SCRIBBLE_CACHES=YES` fills retired arrays before
freeing them to help expose stale readers.

BlocksRuntime's unmodified copy/dispose algorithms are paired with small objc4
Block classes and retain/release callbacks. ARC can copy escaping blocks and
keep their captured Objective-C objects alive. Compiler-generated block data
symbols alias real objc4 classes rather than placeholder arrays.

ObjC exception handling uses the current upstream implementation with ELF
symbol/section spellings and the NDK's C++ exception runtime. Apple crash-report
integration is replaced by Android logcat/stderr diagnostics.

## Validation

Initial native testing uses the existing Android 16 / API 36 arm64 emulator,
with a 4 KB kernel page size. ELF outputs request 16 KB segment alignment; an
actual 16 KB kernel and physical devices still require validation.

Both Debug and Release passed the native suite on this emulator. A separate
parent CMake project also compiled, linked, and ran an ARC client using the
integration example above. GitHub Actions builds both configurations; device
execution currently uses the local adb test script.

The smoke suite checks:

- Class and category discovery, `+load`, `+initialize`, protocol conformance.
- Integer, floating-point, indirect large-struct, super and nil dispatch.
- HFA returns and variadic calls that spill arguments to the stack.
- Strong property replacement, ARC deallocation, zeroing weak references,
  and autorelease-pool cleanup.
- Method implementation replacement and restoration.
- Dynamic class creation, registration, messaging, and disposal.
- Typed Objective-C exceptions and `@finally` cleanup.
- Escaping Blocks and captured-object lifetime.
- Four threads repeatedly allocating, messaging and destroying objects.
- Cache collisions, complete small caches, probe wraparound, and capacity growth.
- A deliberately blocked reader that prevents mutation/reclamation until exit.
- Four readers racing 10,000 method replacements, with synchronous reclamation
  counters and an optional fill-before-free diagnostic.
- `dlopen` image registration and method validity after `dlclose`.

This is a focused native suite, not a claim that Apple's entire test harness
passes on Android.

`scripts/benchmark-android.sh [iterations]` builds and tests Release, runs seven
samples of message dispatch and direct IMP calls, then repeats the benchmark
with the fast path disabled in a separate build directory. It reports median
single-thread latency and four-thread elapsed time per aggregate call. Both
versions use the same compiler, ABI, method body, and synchronization backend;
the latter disables cache-hit lookup. Thread creation/join time is included in
the four-thread number. Emulator measurements are useful for comparisons,
not physical-device performance claims.

## Remaining work

- Further cache-hit optimization, especially atomic-counter contention between
  threads calling the same class; the current guard is not lock-free.
- Block-to-IMP trampolines (`imp_implementationWithBlock`), generic forwarding
  infrastructure such as NSInvocation, and exhaustive ABI/variadic tests.
- Complete private image enumeration APIs, including opaque `dlopen` handles.
- Full fork behavior, sanitizers, memory pressure, long-running stress, and
  mixed Objective-C/C++ exception validation.
- Physical-device and 16 KB kernel testing, other Android architectures,
  installation/exported CMake packages, and broader upstream test adaptation.
- Windows and WebAssembly backends.

Dynamic image unloading is deliberately unavailable; registered images stay
resident for the process lifetime. Swift objects require an appropriate loaded
Swift runtime, and Swift/ObjC interoperability has not been validated here.
