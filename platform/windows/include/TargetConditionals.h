#pragma once

#if !defined(_WIN64)
#error This compatibility header requires 64-bit Windows.
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
#define TARGET_OS_WIN32 1
#define TARGET_RT_64_BIT 1
#if defined(__aarch64__)
#define TARGET_CPU_ARM64 1
#define TARGET_CPU_X86_64 0
#ifndef __arm64__
#define __arm64__ 1
#endif
#else
#define TARGET_CPU_ARM64 0
#define TARGET_CPU_X86_64 1
#endif
