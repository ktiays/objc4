include_guard(GLOBAL)

if(NOT ANDROID)
    message(FATAL_ERROR "Initialize the Android NDK C/C++ toolchain before enabling Objective-C.")
endif()

# Include in the highest CMake directory containing Objective-C targets. The
# NDK configures C/C++, but does not initialize Objective-C compiler targets.
set(CMAKE_OBJC_COMPILER "${CMAKE_C_COMPILER}")
set(CMAKE_OBJCXX_COMPILER "${CMAKE_CXX_COMPILER}")
set(CMAKE_OBJC_COMPILER_TARGET "${CMAKE_C_COMPILER_TARGET}")
set(CMAKE_OBJCXX_COMPILER_TARGET "${CMAKE_CXX_COMPILER_TARGET}")
enable_language(OBJC OBJCXX)
