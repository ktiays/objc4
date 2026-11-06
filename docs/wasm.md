# WebAssembly port

This experimental port builds objc4-951.1 for Emscripten wasm32 and wasm64
(memory64). It retains the
Apple non-fragile metadata ABI and upstream class, selector, protocol, category,
ARC, weak-reference, property, synchronization and autorelease-pool code. It does
not require libobjc2 or Foundation.

## Build

The bootstrap currently supports macOS arm64. Install CMake, Ninja, Python 3.12+
and Node.js. Node 25.9.0 was used for validation.

```sh
python3 scripts/prepare-wasm-toolchain.py --jobs 8
./scripts/test-wasm.sh Debug single
./scripts/test-wasm.sh Release single
./scripts/test-wasm.sh Debug threads
./scripts/test-wasm.sh Release threads
./scripts/test-wasm.sh Debug single wasm64
./scripts/test-wasm.sh Release single wasm64
./scripts/test-wasm.sh Debug threads wasm64
./scripts/test-wasm.sh Release threads wasm64
```

The optional third argument selects `wasm32` (default) or `wasm64`. Both use the
same compiler; no wasm64-specific toolchain is built.

The manifest in `toolchains/wasm/versions.json` pins Emscripten 6.0.13, the SDK
archive SHA-256, and LLVM commit
`5f47feeedda059f88c30ca6f11109faa5ce5428c` with its archive SHA-256.
The bootstrap downloads archives, validates them, applies the patch series, and
builds Clang and LLVM tools. Sources, SDK binaries, caches and builds stay under
ignored `build/wasm-toolchain/`. No compiler checkout or SDK is vendored in Git.

`build-wasm.sh` checks a fingerprint of the manifest, patches and bootstrap
before using an existing compiler. A compiler change also invalidates consumer
object files. Use `OBJC_BUILD_JOBS`, `OBJC_WASM_TOOLCHAIN_ROOT` and
`OBJC_WASM_BUILD_DIR` to override the defaults. The bootstrap accepts
`--node /absolute/path/to/node`, `--download-only`, and `--prepare-only`.

Build products are `build/wasm-{single,threads}-{Debug,Release}/libobjc4.a` for
wasm32 and `build/wasm64-{single,threads}-{Debug,Release}/libobjc4.a` for wasm64,
copied headers under `include/objc/`, and the test executables. The thread mode
and pointer width are separate configurations and must match their consumers.

## Integrate a project

Source the generated environment before configuring the consumer:

```sh
source /path/to/objc4/build/wasm-toolchain/env.sh
emcmake cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Use the repository as a CMake subdirectory:

```cmake
set(OBJC_BUILD_WASM_TESTS OFF CACHE BOOL "" FORCE)
set(OBJC_WASM_THREADS OFF CACHE BOOL "" FORCE) # ON for pthreads
add_subdirectory(/path/to/objc4 objc4-build)
enable_language(OBJC OBJCXX)

add_executable(application main.m)
set_target_properties(application PROPERTIES LINKER_LANGUAGE CXX)
objc4_add_wasm_module(application)
```

For wasm64, configure the consumer the way Emscripten selects wasm64 for CMake:

```sh
emcmake cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS=-sMEMORY64=1 -DCMAKE_CXX_FLAGS=-sMEMORY64=1
```

objc4 derives the target from `CMAKE_SIZEOF_VOID_P`. It adds `-sMEMORY64=1` to
the compile and link options of `objc4_add_wasm_module` targets, because CMake's
Objective-C flags do not inherit `CMAKE_C_FLAGS`. Every object in the program,
including plain C/C++ libraries, must be built for the same pointer width.
Only native memory64 and table64 (`MEMORY64=1`) are supported. `MEMORY64=2`
lowers the main module with wasm-opt, which cannot apply to adapter modules
generated at run time, so configuration rejects it.

Call `objc4_add_wasm_module` for business-code static libraries as well. It
supplies headers, Apple ABI 26.0, Blocks, native Wasm EH, PIC, and the runtime
link settings. Objective-C code and code that calls dispatch or forwarding IMPs
must use the patched compiler. Compile every Block used as an IMP with this
compiler so its actual lowered ABI is available.

`libobjc4.a` is linked statically into the main Wasm program. `MAIN_MODULE=2`
enables Emscripten's dynamic linker for the small runtime adapter modules; it
does not move the Objective-C runtime or business classes into side modules.
Link the final program with Emscripten's C++ driver for libc++abi and Wasm EH.

The image constructor registers linker-collected Objective-C sections and runs
`+load` before `main`. `objc_wasm_init()` is available for explicit, idempotent
initialization. Metadata-bearing objects in an archive still need ordinary
linker reachability. Use `--whole-archive` narrowly for an archive containing
otherwise unreferenced categories or classes, rather than for the entire
application.

## Dispatch and exceptions

Clang emits a hidden COMDAT dispatcher for each lowered calling ABI. A dispatcher
handles nil and superclass sends, resolves the IMP, and invokes it with the
original signature. Cross-file linking deduplicates the dispatchers without
whole-program LTO. Indirect calls also recognize escaped `objc_msgSend` and
forwarding pointers at their eventual typed call sites.

Scalar calls use Wasm tail calls. LLVM currently rejects tail calls with `byval`
arguments, so those signatures use ordinary calls and retain the required
aggregate copies. Variadic dispatch forwards the Wasm C ABI's argument-buffer
pointer. Nil struct returns clear the actual result buffer.

ObjC exceptions use native Wasm EH and libc++abi with Apple-compatible typeinfo.
Typed catches, `@catch(id)`, catch-all, rethrow, `@finally`, and mixed C++/ObjC
unwinding are covered by the tests. The compiler patch implements `@finally`
using a catch-all plus normal cleanup, including returns that suppress an
exception. Runtime `.cxx_construct` and `.cxx_destruct` calls supply both
Objective-C implicit arguments, as required by Wasm's strict function types.

The native instruction-inspection autorelease-return optimization is disabled
on Wasm; ordinary retain/autorelease semantics remain active.

## Forwarding and Block IMPs

Fast forwarding calls `forwardingTargetForSelector:`. The full forwarding channel
is `objc_wasm_set_forward_handler`, declared in `<objc/wasm.h>`. Its invocation
contains the lowered ABI signature, eight-byte argument slots, a result slot and
a typed replay function. A handler can write a result or call
`objc_wasm_invocation_invoke` with a new receiver or compatible IMP. Slots include
the implicit receiver/selector, sret pointer, and variadic-buffer pointer where
applicable. This is a runtime ABI interface; implementing Foundation's
`NSMethodSignature`, `NSInvocation` and `NSProxy` remains Foundation's work.

`imp_implementationWithBlock`, `imp_getBlock` and `imp_removeBlock` use small
generated Wasm modules. Clang records each Block invoke function's lowered ABI;
the runtime does not guess packed records or C++ aggregates from ObjC encodings.
One compiled module template serves a signature; each live Block gets a bound
instance. Removed instances are reused for the same signature. No fixed
signature-by-slot trampoline matrix is reserved.

The adapter modules use Emscripten's dlopen event stream so active, sleeping and
new Workers share the same table indices. The binding cell is published with
atomic release/acquire operations. Table entries remain installed and reusable;
removal clears the Block binding and releases its copy. Callers must finish
uses of an IMP before removing it, as with the native API.

On wasm64 the generated modules import memory64 and table64, use i64 for
pointers, function-table indices, `__memory_base` and `__table_base`, and read
the Block `invoke` field at offset 16. JS receives i64 values as BigInt;
heap indices are computed by division so addresses beyond 2 GiB and 4 GiB index
correctly.

Dynamic adapters currently cover pointers, i32/i64, f32/f64, indirect aggregates,
single-element aggregate coercions and variadic buffers. SIMD vectors and other
extended scalar ABIs need additional adapter encoding support. Ordinary method
sends preserve the compiler's original LLVM function signature.

## Validation and scale

The four wasm32 configurations pass 14 tests in Node.js 25.9.0 and the user's
Chrome 156. The four wasm64 configurations pass 18 tests in Node.js 25.9.0; the
additional wasm64 test links with `GLOBAL_BASE` at 4 GiB. Compiler-emitted
metadata, the stack, the heap, runtime-created classes, method caches, Block
copies, adapter binding cells and forwarding frames then all have nonzero upper
address bits. The browser harness includes any built wasm64 configurations;
that test reserves an initial memory slightly above 4 GiB. Browser results are
saved by the local harness under `build/wasm-browser/results.json`. Run the
browser matrix with:

```sh
python3 scripts/serve-wasm-tests.py
# Open http://127.0.0.1:8127/wasm-browser/index.html in Chrome.
```

The server binds only to loopback and supplies COOP/COEP headers. Pthreads need
cross-origin isolation, shared memory and Workers. Dispatch requires Wasm tail
calls; exceptions require Wasm EH; adapters require runtime Wasm compilation;
wasm64 requires native memory64 and table64 (Chrome 133 or Node.js 24 and later).
Emscripten labels dynamic linking with pthreads experimental, so the passing
matrix is the current validation boundary.

The suites cover image registration, categories, protocols, properties,
`+load`/`+initialize`, nil/super/escaped sends, integers, floating point, aggregate
and packed values, varargs, ARC, weak references, pools, typed exceptions,
finally control flow, C++ cleanup, forwarding, swizzling and Block adapter reuse.
The pthread suite publishes a Worker-created IMP to four Workers while mutating
method caches and exercising object lifetimes.

```sh
source build/wasm-toolchain/env.sh
python3 scripts/test-wasm-large-project.py --count 128 --jobs 8
python3 scripts/test-wasm-large-project.py --count 128 --jobs 8 --memory64
```

The 128-translation-unit fixture links ObjC business files with an ObjC++ entry
point and one copy of a shared dispatch signature,
uses no forced LTO, executes the linked program, then edits one source file.
Exactly that object is rebuilt; the runtime archive remains unchanged. The
recorded timings are fixture measurements affected by SDK and build-cache
state, not projections for an arbitrary production project. Results and logs live under
`build/wasm-large-project/` and `build/wasm64-large-project/`.

The targets are wasm32 and wasm64 with one statically linked ObjC image.
Dynamic loading/unloading of business-class images, Swift interoperation,
Foundation and Apple frameworks are outside this port's current scope. The
bootstrap's host manifest currently contains only macOS arm64.
