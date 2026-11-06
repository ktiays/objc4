#!/usr/bin/env python3
"""Validate separate compilation, dispatcher deduplication and incremental builds."""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import time


REPOSITORY = Path(__file__).resolve().parent.parent


def run(arguments, **options):
    return subprocess.run([str(value) for value in arguments], check=True,
                          text=True, capture_output=True, **options)


def wasm_function_names(path):
    data = path.read_bytes()
    position = 8

    def unsigned():
        nonlocal position
        value, shift = 0, 0
        while True:
            byte = data[position]
            position += 1
            value |= (byte & 127) << shift
            if not byte & 128:
                return value
            shift += 7

    def string():
        nonlocal position
        size = unsigned()
        result = data[position:position + size].decode()
        position += size
        return result

    names = []
    while position < len(data):
        identifier = data[position]
        position += 1
        size = unsigned()
        end = position + size
        if identifier == 0 and string() == "name":
            while position < end:
                subsection = data[position]
                position += 1
                subsection_size = unsigned()
                subsection_end = position + subsection_size
                if subsection == 1:
                    for _ in range(unsigned()):
                        unsigned()
                        names.append(string())
                position = subsection_end
        position = end
    return names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, default=128)
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--memory64", action="store_true", help="Build the fixture for wasm64")
    options = parser.parse_args()
    if options.root is None:
        name = "wasm64-large-project" if options.memory64 else "wasm-large-project"
        options.root = REPOSITORY / "build" / name
    if options.count < 2 or options.jobs < 1:
        parser.error("--count must be at least 2; --jobs must be positive")
    if not shutil.which("emcmake"):
        parser.error("Source build/wasm-toolchain/env.sh first")
    root = options.root.resolve()
    source = root / "source"
    build = root / "build"
    source.mkdir(parents=True, exist_ok=True)
    (source / "Probe.h").write_text(
        '#include <objc/NSObject.h>\n@interface LargeProbe : NSObject\n'
        '- (int)value:(int)value;\n@end\n')
    for index in range(options.count):
        (source / f"unit_{index}.m").write_text(
            '#include "Probe.h"\n'
            f'int unit_{index}(LargeProbe *probe, int value) {{ return [probe value:value] + {index}; }}\n')
    declarations = "\n".join(f"int unit_{index}(LargeProbe *, int);" for index in range(options.count))
    functions = ", ".join(f"unit_{index}" for index in range(options.count))
    (source / "main.mm").write_text(
        '#include "Probe.h"\n#include <assert.h>\n#include <stdio.h>\n#include <string>\n'
        '@implementation LargeProbe\n- (int)value:(int)value { return value + 1; }\n@end\n'
        f'extern "C" {{\n{declarations}\n}}\nint main(void) {{ @autoreleasepool {{\n'
        'std::string message = "PASS: large separate-compilation fixture";\n'
        'LargeProbe *probe = [LargeProbe new];\n'
        f'int (*units[])(LargeProbe *, int) = {{{functions}}};\nint total = 0;\n'
        f'for (int i = 0; i < {options.count}; ++i) total += units[i](probe, i);\n'
        f'assert(total == {options.count ** 2});\nputs(message.c_str());\n}} }}\n')
    # JSON quoting is also valid for these CMake path arguments.
    (source / "CMakeLists.txt").write_text(
        'cmake_minimum_required(VERSION 3.24)\nproject(objc4_large LANGUAGES C CXX)\n'
        'set(OBJC_BUILD_WASM_TESTS OFF CACHE BOOL "" FORCE)\n'
        f'add_subdirectory({json.dumps(str(REPOSITORY))} objc4)\n'
        'enable_language(OBJC OBJCXX)\n'
        'file(GLOB units CONFIGURE_DEPENDS "unit_*.m")\nadd_library(business STATIC ${units})\n'
        'objc4_add_wasm_module(business)\nadd_executable(application main.mm)\n'
        'set_target_properties(application PROPERTIES LINKER_LANGUAGE CXX)\n'
        'objc4_add_wasm_module(application)\n'
        'target_compile_options(application PRIVATE -fobjc-arc -UNDEBUG)\n'
        'target_link_options(application PRIVATE -sEXIT_RUNTIME=1)\n'
        'target_link_libraries(application PRIVATE business)\n')
    started = time.monotonic()
    architecture = (["-DCMAKE_C_FLAGS=-sMEMORY64=1", "-DCMAKE_CXX_FLAGS=-sMEMORY64=1"]
                    if options.memory64 else [])
    configuration = run(["emcmake", "cmake", "-S", source, "-B", build, "-G", "Ninja",
                         "-DCMAKE_BUILD_TYPE=Debug", *architecture])
    (root / "configure.log").write_text(configuration.stdout + configuration.stderr)
    full = run(["cmake", "--build", build, "--parallel", options.jobs])
    (root / "full-build.log").write_text(full.stdout + full.stderr)
    initial_seconds = time.monotonic() - started
    run(["node", build / "application.js"])
    objects = sorted((build / "CMakeFiles/business.dir").glob("unit_*.m.o"))
    assert len(objects) == options.count
    before = {path: path.stat().st_mtime_ns for path in objects}
    runtime = build / "objc4/libobjc4.a"
    runtime_time = runtime.stat().st_mtime_ns
    llvm_nm = REPOSITORY / "build/wasm-toolchain/llvm-build/bin/llvm-nm"
    symbols = run([llvm_nm, "--defined-only", objects[0]]).stdout
    dispatchers = re.findall(r"\bobjc_wasm_msgSend_v1_[a-f0-9]{32}\b", symbols)
    assert len(dispatchers) == 1, dispatchers
    names = wasm_function_names(build / "application.wasm")
    assert names.count(dispatchers[0]) == 1, "Shared dispatcher was not deduplicated"
    changed_source = source / "unit_0.m"
    changed_source.write_text(changed_source.read_text() + "// Incremental build probe.\n")
    started = time.monotonic()
    incremental = run(["cmake", "--build", build, "--parallel", options.jobs])
    incremental_seconds = time.monotonic() - started
    (root / "incremental-build.log").write_text(incremental.stdout + incremental.stderr)
    changed = [path.name for path in objects if path.stat().st_mtime_ns != before[path]]
    assert changed == ["unit_0.m.o"], changed
    assert runtime.stat().st_mtime_ns == runtime_time, "The runtime was rebuilt unnecessarily"
    run(["node", build / "application.js"])
    report = {"architecture": "wasm64" if options.memory64 else "wasm32",
              "translation_units": options.count, "forced_lto": False,
              "common_dispatcher_definitions": names.count(dispatchers[0]),
              "incremental_objects": changed, "runtime_rebuilt": False,
              "initial_seconds": round(initial_seconds, 2),
              "incremental_seconds": round(incremental_seconds, 2)}
    (root / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
