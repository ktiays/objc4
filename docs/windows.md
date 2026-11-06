# Windows port

This port builds the upstream objc4 runtime as `objc4.dll` for Windows ARM64
and x64. It uses Clang's Apple Objective-C metadata ABI on PE/COFF, with the
platform's native calling convention. It does not use the GNUstep runtime ABI.

## Build and test

Use CMake 3.24 or newer, Ninja, and the UCRT variant of
[LLVM-MinGW](https://github.com/mstorsjo/llvm-mingw). The validated toolchain is
release **20261104**, with Clang **23.1.5**. The ARM64-hosted distribution
contains compilers and libraries for both target architectures; the x64-hosted
distribution can also target both.

Add CMake and Ninja to `PATH`, extract LLVM-MinGW, and run from PowerShell:

```powershell
$env:LLVM_MINGW_ROOT = 'C:\tools\llvm-mingw-20261104-ucrt-aarch64'
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-windows.ps1 -Configuration Debug -Architecture aarch64
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-windows.ps1 -Configuration Release -Architecture aarch64
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-windows.ps1 -Configuration Debug -Architecture x86_64
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-windows.ps1 -Configuration Release -Architecture x86_64
```

The execution-policy override applies only to that PowerShell process.
`build-windows.ps1` builds without running tests. Both scripts accept `-Jobs`.
Outputs go under `build/windows-<architecture>-<configuration>/`, including
`objc4.dll`, its import library, generated `include/objc/` headers, and the
libc++, libunwind, and winpthreads DLLs needed to run the tests. An ARM64 Windows
host can run x64 tests through Windows' x64 emulation. This is distinct from
execution on physical x64 hardware.

The same CMake toolchain supports cross-compilation from macOS or Linux with
the corresponding LLVM-MinGW host distribution:

```sh
export LLVM_MINGW_ROOT=/path/to/llvm-mingw
cmake -S . -B build/windows-aarch64-Debug -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=platform/windows/llvm-mingw.cmake \
  -DOBJC_WINDOWS_ARCH=aarch64 -DCMAKE_BUILD_TYPE=Debug
cmake --build build/windows-aarch64-Debug
```

## Integrating a consumer

Configure the consumer with the same toolchain. Add this repository as a CMake
subdirectory and attach the helper to **each final executable or DLL** that
contains Objective-C metadata:

```cmake
project(Example LANGUAGES C CXX)
set(OBJC_BUILD_WINDOWS_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(objc4)
enable_language(OBJC OBJCXX)
add_executable(example main.mm)
objc4_add_windows_module(example)
target_compile_options(example PRIVATE -fobjc-arc)
```

The helper supplies the COFF section bounds and registration constructor,
selects `-fobjc-runtime=macosx-26.0`, enables Blocks, and links the runtime. The
`macosx` spelling selects the metadata contract; the machine code still targets
Windows. Use one compatible Objective-C ABI and one instance of `objc4.dll`
throughout the process. Plain C/C++ clients can link the `objc` CMake target and
use the runtime headers without a module registration helper.

Object files containing Objective-C classes must actually be included in the
final link. Classes held only in a static archive may require whole-archive
linking. Apply the registration helper to the final image, rather than to the
archive.

Deploy `objc4.dll`, `libc++.dll`, `libunwind.dll`, and `libwinpthread-1.dll` from
the matching target architecture beside the application. The import library
is used at build time. This configuration uses the LLVM-MinGW C++ ABI;
clang-cl/MSVC C++ exception interoperability is outside the supported build.

## Implementation

The shared sources provide classes, selectors, protocols, categories,
properties, method resolution, associations, synchronization, ARC, weak
references, and autorelease pools. Windows supplies image registration,
allocation helpers, diagnostics, random bytes, exception integration, and
message dispatch.

* Clang emits metadata into `.objc_*` COFF sections with `$B` contributions.
  Per-image `$A`/`$Z` bounds collect those contributions without depending on
  truncated PE section names. Registration maps classes and categories before
  invoking `+load`.
* Windows uses LLP64. Pointer-sized layouts and masks use pointer width,
  while `NSInteger` and `NSUInteger` use `intptr_t` and `uintptr_t`. The runtime
  uses raw isa pointers and outlined method caches.
* ARM64 and x64 dispatchers preserve integer, floating-point, stack, and hidden
  aggregate-return arguments while looking up the IMP. SEH unwind information
  covers their non-leaf lookup frames. Cache probes use a reader/writer barrier
  before old bucket arrays are reclaimed.
* Objective-C exceptions use libc++abi type matching and the MinGW SEH
  personality. Typed catches, rethrows, `@finally`, C++ cleanup, throwing
  `+initialize`, and `@synchronized` cleanup are tested together.
* BlocksRuntime supplies copy/dispose behavior. Block IMPs use Windows virtual
  memory: writable while generated, executable and read-only before use.
  Callers must finish invoking an IMP before calling `imp_removeBlock`.

## Validation and boundaries

The Windows suite covers executable and DLL registration, class/category
`+load`, `+initialize`, protocols, properties, ARC/weak/pools, integer and FP
register/stack arguments, variadic calls, aggregate arguments and returns,
super sends, nil scalar returns, dynamic resolution, forwarding handlers,
Block IMP ownership/returns, dynamic class disposal, cache growth, and
concurrent cache mutation and Block IMP publication/removal.

Validation used the native ARM64 LLVM-MinGW compiler on a Windows ARM64 VM:

| Target | Debug | Release | Execution |
| --- | --- | --- | --- |
| ARM64 | 4/4 passed | 4/4 passed | Native ARM64 |
| x64 | 4/4 passed | 4/4 passed | Windows x64 emulation |

An independent CMake consumer also passed property, association, and image
enumeration checks. Shared-source regression checks passed Wasm single-thread
Debug (3/3) and pthreads Release (4/4), plus an Android arm64 Debug build. Android
device tests were not run because no device or emulator was connected.

Registered Objective-C DLLs are pinned with `GetModuleHandleExW`; calling
`FreeLibrary` does not unload their classes or metadata. Arbitrary Objective-C
DLL unloading is not supported. Image constructors and `+load` in a DLL run
under the Windows loader lock, so they must follow Windows DLL initialization
constraints, including avoiding waits for newly created threads.

This port does not supply Foundation, Apple SDK frameworks, Swift Objective-C
interoperability, dyld shared caches, tagged/nonpointer isa optimizations,
Apple's autorelease-return instruction optimization, or 32-bit Windows.
Forwarding through an installed `objc_setForwardHandler` is supported;
Foundation's `NSInvocation` forwarding machinery is not provided here. Use
properly typed function pointers when calling dispatch APIs directly;
aggregate results for a nil receiver through a raw dispatcher are not
guaranteed to be initialized.
