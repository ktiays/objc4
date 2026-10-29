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
and dynamically loaded test images. `scripts/test-android.sh Debug` also runs
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

ELF registration is serialized and reentrant for `+load`. A reader/writer lock
protects image/range records, allowing controlled removal without accumulating
retired image descriptors. Ordinary shared objects use `RTLD_NODELETE`; metadata
and method pointers remain valid after callers release raw `dlopen` handles.

## Controlled class-plugin unloading

Shared/module libraries can explicitly opt into the managed unloading contract:

```cmake
add_library(my_plugin SHARED plugin.m)
set_target_properties(my_plugin PROPERTIES LINKER_LANGUAGE CXX)
objc4_add_android_module(my_plugin UNLOADABLE)
target_compile_options(my_plugin PRIVATE -fobjc-arc)
```

The public APIs are declared in `<objc/android.h>`. Open with
`objc_android_module_open`, acquire an execution lease before entering plugin
code or inspecting its metadata, and release the lease only after all related
calls and ARC/exception cleanup have completed. `objc_android_module_symbol`
requires a lease and returns a borrowed native export. `Class`, `Method`, IMPs,
callback pointers, and Blocks must not be used after their protecting lease ends
or after the module closes. Escaped callbacks/Blocks retain a lease for their
whole usable lifetime. Acquire dependency-module leases when loading or
unloading a dependent plugin.

An ARC client's successful-use sequence is:

```objc
objc_android_module_handle *module = NULL;
objc_android_module_result result = objc_android_module_open("libmy_plugin.so", &module);
// Check result == OBJC_ANDROID_MODULE_OK before proceeding.
result = objc_android_module_acquire(module);
// Check result == OBJC_ANDROID_MODULE_OK before entering the protected scope.
@try {
    @autoreleasepool {
        Class cls = objc_getClass("MyPlugin");
        id object = [cls new];
        // Use object and any borrowed plugin metadata here.
    }
} @finally {
    objc_android_module_release(module);
}
result = objc_android_module_close(module);
if (result == OBJC_ANDROID_MODULE_OK) {
    objc_android_module_destroy(module);
} else {
    // Keep the handle, inspect the status, clean up under a lease, and retry.
}
```

Stop producers, finish asynchronous work, and drain autorelease pools before
closing. Do not open/close managed modules from ELF constructors, `+load`, or
ELF finalizers. Use an explicit shutdown export under a lease to release ObjC
globals and unregister external callbacks; finalizers run after class metadata
has been removed and must not message or create plugin objects. Plugins cannot
leave permanent process hooks or unleased callbacks/Blocks in other libraries.
This cooperative contract is necessary because arbitrary raw pointers and
direct function calls cannot be discovered by the runtime.

The runtime additionally tracks ordinary allocation, construction, copying,
batch allocation, destruction, and `object_setClass`. Idle tracked instances
prevent close even if no lease is active; accessing or releasing them still
needs a lease. Direct `isa` writes and unmanaged custom allocation/destruction
are outside this check; class-object ISA rewriting is outside the unloading
contract. Cloned classes that share plugin metaclasses also block closing, even
if their instance IMPs are replaced. Upstream clones do not offer a general
public disposal path, so they can require keeping that plugin resident.
Tracking is bypassed when no eligible unloadable images
are loaded; message dispatch does not gain per-message instance bookkeeping.

| Close/open result | Meaning |
| --- | --- |
| `BUSY_LEASES` | Active execution leases; finish those scopes before closing. |
| `BUSY_OBJECTS` | Tracked instances remain; release them under a lease. |
| `DEPENDENCY` | Another class/image references the plugin, an external method uses its IMP, class associations remain, or class mappings were replaced. Remove those dependencies before retrying. |
| `UNSUPPORTED` | Categories, protocol definitions, Swift/stub metadata, or unknown registration flags are not supported for unloading. |
| `CLOSED` | A close is in progress or metadata has already been removed. |

The first supported format is class plugins without Category/protocol/Swift
definitions. Unsupported modules stay resident and `open` returns `UNSUPPORTED`
with no managed handle. Native constructors and ObjC registration have already
run at that point; rejection is not transactional rollback of their effects.
Normal non-opt-in modules return `NOT_UNLOADABLE` and retain their existing
residency behavior.

Close blocks new leases for preflight and checks runtime dependencies. On
success, it flushes method caches, reuses objc4's class detachment/freeing logic,
removes image/range records, and releases its native loader references.
Selectors are interned outside the mapping; APIs that retain string inputs copy
them from unloadable images as needed. Borrowed reflection results still require
a lease. Image-name strings are kept once per distinct path for the process
lifetime, so a saved `objc_copyImageNames`/`class_getImageName` path does not
dangle when an image descriptor is removed.
Extra raw `dlopen` handles, native dependencies, or an independently set
`RTLD_NODELETE` can keep ELF pages mapped after logical close. Use managed
ownership throughout when actual unmapping is required.
Reloading requires those outside native references to be dropped so that ELF
constructors can run again; a still-mapped, logically closed image cannot reopen
as a managed module.

Busy/dependency failures leave the module open. A native `dlclose` error after
metadata removal leaves it closed. A closed handle remains valid for `CLOSED`
results until `destroy`; the owner must join/synchronize all users before
destroying the handle. Bare metadata pointers become invalid at successful
close and must not be reused on a later load.

## Dispatch and object lifetime

The AAPCS64 dispatcher probes the upstream method cache in assembly and
tail-calls a cached IMP without taking `runtimeLock`, creating a stack frame,
or saving argument registers. Cache misses save x0–x8 and v0–v7, ask upstream
objc4 to find/initialize/resolve the method, then restore the original arguments
and tail-call the IMP. It supports super dispatch and nil scalar/FP/HFA returns.
Large indirect results preserve x8. The cache layout, selector hash, and IMP
encoding have compile-time checks against the C++ implementation.

The Android synchronization mechanism is a table of 256 64-byte-aligned
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

Native testing covers Android 16 / API 36 arm64 emulators with both 4 KB and
16 KB kernel page sizes. The official `google_apis_ps16k` image was booted and
`getconf PAGESIZE` returned `16384`; both Debug and Release passed the runtime
and concurrent cache suites there. The fill-before-free cache diagnostic also
passed on both kernel page sizes. ELF outputs request 16 KB segment alignment.
Physical devices still require validation.

Both Debug and Release also passed the native suite on the 4 KB emulator. A separate
parent CMake project also compiled, linked, and ran an ARC client using the
integration example above. Device execution uses the local adb test script.

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
- Controlled unload/reload cycles, `+load`/`+initialize` reset, class/image-table
  removal, permanent selector lifetime, and actual ELF mapping removal.
- Refusal with live objects, execution leases, class associations, external
  dynamic subclasses or methods, shared-metaclass clones, and dependent ELF class plugins.
- Construction/copy/batch/ISA-change tracking, ARC/weak/exception cleanup,
  concurrent acquire/close, and runtime-lock contention during closing.

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

For example, on the local Android 16 / API 36 arm64 emulator with a 4 KB kernel,
NDK 29 Release, one million aggregate calls per sample, and seven samples
(2026-10-29), the benchmark reported:

| Mode | Single-thread ns/call | Four-thread ns/aggregate call |
| --- | ---: | ---: |
| Guarded cache | 6.47 | 16.95 |
| Fast path disabled | 9.85 | 24.29 |

Direct IMP calls were 0.70–0.71 ns/call in the same runs. The guarded path
reduced elapsed time by about 34% and 30%, respectively. These are one emulator's
measurements and will vary with device, scheduling, and workload.

## Remaining work

- Further cache-hit optimization, especially atomic-counter contention between
  threads calling the same class; the current guard is not lock-free.
- Block-to-IMP trampolines (`imp_implementationWithBlock`), generic forwarding
  infrastructure such as NSInvocation, and exhaustive ABI/variadic tests.
- Complete private image enumeration APIs, including opaque `dlopen` handles.
- Broader controlled unloading, especially protocol definitions, Categories,
  and stronger diagnostics for escaped native callbacks or unmanaged lifetimes.
- Full fork behavior, sanitizers, memory pressure, long-running stress, and
  mixed Objective-C/C++ exception validation.
- Physical-device testing, other Android architectures,
  installation/exported CMake packages, and broader upstream test adaptation.
- Windows and WebAssembly backends.

General automatic unloading of arbitrary images is not implemented. Swift
objects require an appropriate loaded Swift runtime, and Swift/ObjC
interoperability has not been validated here.
