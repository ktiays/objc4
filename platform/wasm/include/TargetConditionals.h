#pragma once

#if !defined(__wasm__)
#error This compatibility header is for WebAssembly builds only.
#endif

#define TARGET_OS_MAC 0
#define TARGET_OS_OSX 0
#define TARGET_OS_IPHONE 0
#define TARGET_OS_IOS 0
#define TARGET_OS_TV 0
#define TARGET_OS_WATCH 0
#define TARGET_OS_BRIDGE 0
#define TARGET_OS_VISION 0
#define TARGET_OS_MACCATALYST 0
#define TARGET_OS_SIMULATOR 0
#define TARGET_OS_DRIVERKIT 0
#define TARGET_OS_EXCLAVEKIT 0
#define TARGET_OS_EXCLAVECORE 0
#define TARGET_CPU_ARM64 0
#define TARGET_CPU_X86_64 0
#if defined(__LP64__)
#define TARGET_RT_64_BIT 1
#else
#define TARGET_RT_64_BIT 0
#endif
