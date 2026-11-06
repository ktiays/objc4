include_guard(GLOBAL)

if(NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang" OR MSVC)
    message(FATAL_ERROR "The Windows port requires LLVM-MinGW with libc++ (use platform/windows/llvm-mingw.cmake).")
endif()
if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "The Windows port requires ARM64 or x64.")
endif()
set(CMAKE_OBJC_COMPILER "${CMAKE_C_COMPILER}")
set(CMAKE_OBJCXX_COMPILER "${CMAKE_CXX_COMPILER}")
enable_language(OBJC OBJCXX ASM)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(OBJC_APPLE_ABI_VERSION "26.0" CACHE STRING "Apple Objective-C metadata ABI")
option(OBJC_BUILD_WINDOWS_TESTS "Build native Windows runtime tests" ON)

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/include/objc")
file(GLOB OBJC_HEADERS CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/runtime/*.h")
foreach(header IN LISTS OBJC_HEADERS)
    get_filename_component(name "${header}" NAME)
    configure_file("${header}" "${CMAKE_CURRENT_BINARY_DIR}/include/objc/${name}" COPYONLY)
endforeach()
configure_file(platform/windows/include/objc/windows.h include/objc/windows.h COPYONLY)

set(OBJC_CORE_SOURCES
    runtime/hashtable2.mm runtime/maptable.mm runtime/objc-accessors.mm
    runtime/objc-auto.mm runtime/objc-cache.mm runtime/objc-class.mm
    runtime/objc-initialize.mm runtime/objc-layout.mm runtime/objc-load.mm
    runtime/objc-loadmethod.mm runtime/objc-lockdebug.mm
    runtime/objc-runtime-new.mm runtime/objc-runtime.mm runtime/objc-sel.mm
    runtime/objc-sync.mm runtime/objc-typeencoding.mm runtime/objc-references.mm
    runtime/objc-weak.mm runtime/Object.mm runtime/Protocol.mm runtime/NSObject.mm
    runtime/objc-opt.mm runtime/objc-zalloc.mm)

if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|ARM64|arm64)$")
    set(windows_dispatch platform/windows/objc-msg-arm64.S)
else()
    set(windows_dispatch platform/windows/objc-msg-x86_64.S)
endif()
# MinGW executes default-priority .ctors in reverse link order. Register the
# runtime's image after its C++ lock and TLS-key constructors have completed.
add_library(objc SHARED platform/windows/objc-coff-module.c
    ${OBJC_CORE_SOURCES} ${windows_dispatch}
    platform/windows/objc4.def
    platform/windows/objc-os-windows.mm
    platform/windows/objc-cache-windows.mm
    platform/windows/objc-errors-windows.mm
    platform/windows/objc-blocks-windows.mm
    platform/windows/objc-exception-windows.mm
    third-party/BlocksRuntime/runtime.c)
set_target_properties(objc PROPERTIES OUTPUT_NAME objc4 PREFIX "")
target_include_directories(objc PUBLIC "${CMAKE_CURRENT_BINARY_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/platform/windows/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/include"
    PRIVATE runtime platform/windows third-party/BlocksRuntime)
target_compile_definitions(objc PRIVATE
    OS_OBJECT_USE_OBJC=0 _LIBCPP_VISIBLE= OBJC_WINDOWS_PORT=1
    BlocksRuntime_EXPORTS=1
    CONFIG_USE_PREOPT_CACHES=0 CONFIG_USE_PREOPT_CACHES_BUILD_ONLY=0
    $<$<CONFIG:Debug>:DEBUG=1;OBJC_IS_DEBUG_BUILD=1>)
target_compile_options(objc PRIVATE
    "$<$<NOT:$<COMPILE_LANGUAGE:ASM>>:-include;${CMAKE_CURRENT_SOURCE_DIR}/platform/windows/include/objc-windows-compiler.h>"
    "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fno-objc-arc;-fobjc-runtime=macosx-${OBJC_APPLE_ABI_VERSION};-fno-objc-convert-messages-to-runtime-calls>"
    "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-fno-rtti>"
    -fblocks -Wno-deprecated-declarations -Wno-unused-command-line-argument)
target_link_libraries(objc PUBLIC winpthread PRIVATE bcrypt)
target_link_options(objc PRIVATE "LINKER:--export-all-symbols")

function(objc4_add_windows_module target)
    target_sources(${target} PRIVATE "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/objc-coff-module.c")
    target_compile_options(${target} PRIVATE -fblocks
        "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-runtime=macosx-${OBJC_APPLE_ABI_VERSION};-fno-objc-convert-messages-to-runtime-calls>"
        -include "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/include/objc-windows-compiler.h")
    target_link_libraries(${target} PRIVATE objc)
endfunction()

if(OBJC_BUILD_WINDOWS_TESTS)
    enable_testing()
    foreach(test IN ITEMS smoke abi exceptions threads)
        add_executable(objc4-windows-${test} test/windows/${test}.mm)
        objc4_add_windows_module(objc4-windows-${test})
        target_compile_options(objc4-windows-${test} PRIVATE -fobjc-arc -UNDEBUG)
        add_test(NAME objc4-windows-${test} COMMAND objc4-windows-${test})
        set_tests_properties(objc4-windows-${test} PROPERTIES TIMEOUT 90)
    endforeach()
    add_library(objc4-windows-plugin SHARED test/windows/plugin.mm)
    set_target_properties(objc4-windows-plugin PROPERTIES PREFIX "")
    objc4_add_windows_module(objc4-windows-plugin)
    target_compile_options(objc4-windows-plugin PRIVATE -fobjc-arc)
    add_dependencies(objc4-windows-smoke objc4-windows-plugin)
endif()
