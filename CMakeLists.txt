cmake_minimum_required(VERSION 3.24)
project(objc4 LANGUAGES C CXX ASM)

if(NOT ANDROID OR NOT CMAKE_ANDROID_ARCH_ABI STREQUAL "arm64-v8a")
    message(FATAL_ERROR "The CMake port currently targets Android arm64-v8a. Apple builds continue to use objc.xcodeproj.")
endif()

if(ANDROID_NATIVE_API_LEVEL LESS 26)
    message(FATAL_ERROR "The Android backend requires API level 26 or newer.")
endif()
include(platform/android/objc4-enable-languages.cmake)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(OBJC_APPLE_ABI_VERSION "26.0" CACHE STRING "Apple ObjC ABI/code-generation version used for Android modules")
option(OBJC_BUILD_ANDROID_TESTS "Build native Android runtime tests" ON)
option(OBJC_ANDROID_CACHE_FASTPATH "Use guarded assembly cache hits for Android messaging" ON)

set(OBJC_ANDROID_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/include")
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/include/objc")
file(GLOB OBJC_HEADERS CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/runtime/*.h")
foreach(header IN LISTS OBJC_HEADERS)
    get_filename_component(name "${header}" NAME)
    configure_file("${header}" "${CMAKE_CURRENT_BINARY_DIR}/include/objc/${name}" COPYONLY)
endforeach()

set(OBJC_CORE_SOURCES
    runtime/hashtable2.mm runtime/maptable.mm runtime/objc-accessors.mm
    runtime/objc-auto.mm runtime/objc-cache.mm runtime/objc-class.mm
    runtime/objc-initialize.mm runtime/objc-layout.mm runtime/objc-load.mm
    runtime/objc-loadmethod.mm runtime/objc-lockdebug.mm
    runtime/objc-runtime-new.mm runtime/objc-runtime.mm runtime/objc-sel.mm
    runtime/objc-sync.mm runtime/objc-typeencoding.mm runtime/objc-references.mm
    runtime/objc-weak.mm runtime/Object.mm runtime/Protocol.mm runtime/NSObject.mm
    runtime/objc-opt.mm runtime/objc-zalloc.mm)

add_library(objc-core OBJECT ${OBJC_CORE_SOURCES})
target_include_directories(objc-core PUBLIC
    "${CMAKE_CURRENT_BINARY_DIR}/include" "${OBJC_ANDROID_INCLUDE}"
    PRIVATE runtime platform/android third-party/BlocksRuntime)
target_compile_definitions(objc-core PRIVATE
    OS_OBJECT_USE_OBJC=0 _LIBCPP_VISIBLE= OBJC_ANDROID_PORT=1
    CONFIG_USE_PREOPT_CACHES=0 CONFIG_USE_PREOPT_CACHES_BUILD_ONLY=0
    $<$<CONFIG:Debug>:DEBUG=1;OBJC_IS_DEBUG_BUILD=1>)
target_compile_options(objc-core PRIVATE
    -include "${OBJC_ANDROID_INCLUDE}/objc-android-compiler.h"
    -fblocks -fno-objc-arc -fobjc-runtime=macosx-${OBJC_APPLE_ABI_VERSION}
    -fno-objc-convert-messages-to-runtime-calls
    -fno-exceptions -fno-rtti -fvisibility=hidden
    -Wno-deprecated-declarations -Wno-unused-command-line-argument)

add_library(objc SHARED
    platform/android/objc-cache-android.mm
    platform/android/objc-os-android.mm
    platform/android/objc-errors-android.mm
    platform/android/objc-diagnostics-android.cpp
    platform/android/objc-blocks-android.mm
    platform/android/objc-runtime-image.c
    platform/android/objc-msg-arm64.S
    runtime/objc-exception.mm
    third-party/BlocksRuntime/runtime.c)
target_link_libraries(objc PUBLIC objc-core PRIVATE log dl)
get_target_property(coreOptions objc-core COMPILE_OPTIONS)
get_target_property(coreDefinitions objc-core COMPILE_DEFINITIONS)
target_compile_options(objc PRIVATE ${coreOptions})
target_compile_definitions(objc PRIVATE ${coreDefinitions}
    OBJC_ANDROID_CACHE_FASTPATH=$<BOOL:${OBJC_ANDROID_CACHE_FASTPATH}>
    OBJC_ANDROID_TESTING=$<BOOL:${OBJC_BUILD_ANDROID_TESTS}>)
target_include_directories(objc PRIVATE runtime platform/android third-party/BlocksRuntime)
set_source_files_properties(runtime/objc-exception.mm PROPERTIES COMPILE_OPTIONS "-fexceptions;-fcxx-exceptions")
target_link_options(objc PRIVATE
    "LINKER:-T,${CMAKE_CURRENT_SOURCE_DIR}/platform/android/objc-metadata.ld"
    "LINKER:-z,max-page-size=16384" "LINKER:--no-undefined")
set_target_properties(objc PROPERTIES OUTPUT_NAME objc4)

function(objc4_add_android_module target)
    target_sources(${target} PRIVATE "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/platform/android/objc-elf-module.c")
    target_compile_options(${target} PRIVATE -fblocks
        "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-runtime=macosx-${OBJC_APPLE_ABI_VERSION}>")
    target_link_options(${target} PRIVATE
        "LINKER:-T,${CMAKE_CURRENT_FUNCTION_LIST_DIR}/platform/android/objc-metadata.ld"
        "LINKER:-z,max-page-size=16384")
    target_link_libraries(${target} PRIVATE objc)
endfunction()

if(OBJC_BUILD_ANDROID_TESTS)
    add_library(objc4-test-plugin SHARED test/android/plugin.m)
    set_target_properties(objc4-test-plugin PROPERTIES LINKER_LANGUAGE CXX)
    objc4_add_android_module(objc4-test-plugin)
    target_compile_options(objc4-test-plugin PRIVATE -fobjc-arc)
    add_executable(objc4-android-smoke test/android/smoke.m)
    set_target_properties(objc4-android-smoke PROPERTIES LINKER_LANGUAGE CXX)
    objc4_add_android_module(objc4-android-smoke)
    target_compile_options(objc4-android-smoke PRIVATE -fobjc-arc -UNDEBUG)
    foreach(test IN ITEMS cache benchmark)
        add_executable(objc4-android-${test} test/android/${test}.m)
        set_target_properties(objc4-android-${test} PROPERTIES LINKER_LANGUAGE CXX)
        objc4_add_android_module(objc4-android-${test})
        target_compile_options(objc4-android-${test} PRIVATE -fobjc-arc -UNDEBUG)
    endforeach()
    target_compile_definitions(objc4-android-benchmark PRIVATE
        OBJC_ANDROID_CACHE_FASTPATH=$<BOOL:${OBJC_ANDROID_CACHE_FASTPATH}>)
endif()
