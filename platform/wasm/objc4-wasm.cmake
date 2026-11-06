include_guard(GLOBAL)

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 4)
    message(FATAL_ERROR "The current objc4 WebAssembly adapters require wasm32.")
endif()

set(CMAKE_OBJC_COMPILER "${CMAKE_C_COMPILER}")
set(CMAKE_OBJCXX_COMPILER "${CMAKE_CXX_COMPILER}")
enable_language(OBJC OBJCXX)
# emcc selects its system libraries from the final link options. As with the
# Emscripten toolchain's C/C++ setup, CMake must not append libraries detected
# during a compiler probe with a different EH, PIC or pthread configuration.
foreach(language IN ITEMS OBJC OBJCXX)
    set(CMAKE_${language}_IMPLICIT_LINK_LIBRARIES "")
    set(CMAKE_${language}_IMPLICIT_LINK_DIRECTORIES "")
endforeach()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(OBJC_WASM_THREADS "Build the pthreads variant" OFF)
option(OBJC_BUILD_WASM_TESTS "Build the WebAssembly runtime tests" ON)
set(OBJC_APPLE_ABI_VERSION "26.0" CACHE STRING "Apple Objective-C metadata ABI")

set(OBJC_CORE_SOURCES
    runtime/hashtable2.mm runtime/maptable.mm runtime/objc-accessors.mm
    runtime/objc-auto.mm runtime/objc-cache.mm runtime/objc-class.mm
    runtime/objc-initialize.mm runtime/objc-layout.mm runtime/objc-load.mm
    runtime/objc-loadmethod.mm runtime/objc-lockdebug.mm
    runtime/objc-runtime-new.mm runtime/objc-runtime.mm runtime/objc-sel.mm
    runtime/objc-sync.mm runtime/objc-typeencoding.mm runtime/objc-references.mm
    runtime/objc-weak.mm runtime/Object.mm runtime/Protocol.mm runtime/NSObject.mm
    runtime/objc-opt.mm runtime/objc-zalloc.mm)

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/include/objc")
file(GLOB OBJC_HEADERS CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/runtime/*.h")
foreach(header IN LISTS OBJC_HEADERS)
    get_filename_component(name "${header}" NAME)
    configure_file("${header}" "${CMAKE_CURRENT_BINARY_DIR}/include/objc/${name}" COPYONLY)
endforeach()
configure_file(platform/wasm/include/objc/wasm.h include/objc/wasm.h COPYONLY)

add_library(objc STATIC ${OBJC_CORE_SOURCES}
    platform/wasm/objc-cache-wasm.mm
    platform/wasm/objc-os-wasm.mm
    platform/wasm/objc-errors-wasm.mm
    platform/wasm/objc-blocks-wasm.mm
    platform/wasm/objc-adapters-wasm.mm
    platform/wasm/objc-exception-wasm.mm
    third-party/BlocksRuntime/runtime.c)
set_target_properties(objc PROPERTIES OUTPUT_NAME objc4)
target_include_directories(objc PUBLIC "${CMAKE_CURRENT_BINARY_DIR}/include"
    PRIVATE platform/wasm/include platform/android/include runtime
            platform/wasm third-party/BlocksRuntime)
target_compile_definitions(objc PRIVATE
    OS_OBJECT_USE_OBJC=0 _LIBCPP_VISIBLE= OBJC_WASM_PORT=1
    CONFIG_USE_PREOPT_CACHES=0 CONFIG_USE_PREOPT_CACHES_BUILD_ONLY=0
    $<$<CONFIG:Debug>:DEBUG=1;OBJC_IS_DEBUG_BUILD=1>)
target_compile_options(objc PRIVATE
    -include "${CMAKE_CURRENT_SOURCE_DIR}/platform/wasm/include/objc-wasm-compiler.h"
    -fblocks -fno-objc-arc -fobjc-runtime=macosx-${OBJC_APPLE_ABI_VERSION}
    -fno-objc-convert-messages-to-runtime-calls -fno-rtti -fvisibility=hidden
    -Wno-deprecated-declarations -Wno-unused-command-line-argument)
target_compile_options(objc PUBLIC -mtail-call -fwasm-exceptions -fPIC)
get_filename_component(wasm_toolchain_root "$ENV{EM_CONFIG}" DIRECTORY)
if(EXISTS "${wasm_toolchain_root}/build-fingerprint")
    file(READ "${wasm_toolchain_root}/build-fingerprint" wasm_toolchain_fingerprint)
    string(STRIP "${wasm_toolchain_fingerprint}" wasm_toolchain_fingerprint)
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
        "${wasm_toolchain_root}/build-fingerprint")
    target_compile_definitions(objc PUBLIC
        "OBJC_WASM_COMPILER_REVISION=${wasm_toolchain_fingerprint}")
endif()
target_link_options(objc INTERFACE -mtail-call -fwasm-exceptions
    -sMAIN_MODULE=2
    -sALLOW_TABLE_GROWTH=1 -sALLOW_MEMORY_GROWTH=1
    "LINKER:--undefined=objc_wasm_init"
    "LINKER:--export=objc_wasm_forward_invoke"
    "LINKER:--export=__heap_base"
    "--js-library=${CMAKE_CURRENT_LIST_DIR}/library-objc4.js")
set_property(TARGET objc PROPERTY INTERFACE_LINK_DEPENDS
    "${CMAKE_CURRENT_LIST_DIR}/library-objc4.js")
if(OBJC_WASM_THREADS)
    target_compile_options(objc PUBLIC -pthread)
    target_link_options(objc INTERFACE -pthread)
endif()

function(objc4_add_wasm_module target)
    # A consumer may enable these languages after add_subdirectory returns,
    # reloading the compiler-probe libraries into its directory scope.
    foreach(language IN ITEMS OBJC OBJCXX)
        set(CMAKE_${language}_IMPLICIT_LINK_LIBRARIES "" PARENT_SCOPE)
        set(CMAKE_${language}_IMPLICIT_LINK_DIRECTORIES "" PARENT_SCOPE)
    endforeach()
    target_compile_options(${target} PRIVATE -fblocks
        "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-runtime=macosx-${OBJC_APPLE_ABI_VERSION}>"
        -fno-objc-convert-messages-to-runtime-calls)
    target_include_directories(${target} PRIVATE
        "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/include"
        "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../android/include")
    target_compile_options(${target} PRIVATE
        -include "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/include/objc-wasm-compiler.h")
    target_link_libraries(${target} PRIVATE objc)
endfunction()

if(OBJC_BUILD_WASM_TESTS)
    enable_testing()
    set(wasm_tests smoke exceptions adapters)
    if(OBJC_WASM_THREADS)
        list(APPEND wasm_tests threads)
    endif()
    foreach(test IN LISTS wasm_tests)
        if(test STREQUAL smoke)
            set(extension m)
        else()
            set(extension mm)
        endif()
        add_executable(objc4-wasm-${test} test/wasm/${test}.${extension})
        set(wasm_test_name objc4-wasm-${test})
        configure_file(test/wasm/browser.html ${wasm_test_name}.html @ONLY)
        set_target_properties(objc4-wasm-${test} PROPERTIES LINKER_LANGUAGE CXX)
        objc4_add_wasm_module(objc4-wasm-${test})
        target_compile_options(objc4-wasm-${test} PRIVATE -fobjc-arc -UNDEBUG)
        target_link_options(objc4-wasm-${test} PRIVATE -sEXIT_RUNTIME=1)
        if(OBJC_WASM_THREADS)
            target_link_options(objc4-wasm-${test} PRIVATE -sPTHREAD_POOL_SIZE=5 -sPROXY_TO_PTHREAD=1)
        endif()
        add_test(NAME objc4-wasm-${test}
            COMMAND ${CMAKE_CROSSCOMPILING_EMULATOR} $<TARGET_FILE:objc4-wasm-${test}>)
        set_tests_properties(objc4-wasm-${test} PROPERTIES TIMEOUT 90)
    endforeach()
endif()
