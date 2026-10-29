#pragma once
#include <TargetConditionals.h>
#include <Availability.h>
#ifndef __ASSEMBLER__
#include <sys/cdefs.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#ifndef __unused
#define __unused __attribute__((unused))
#endif
#ifndef __printflike
#define __printflike(formatIndex, firstArgument) __attribute__((format(printf, formatIndex, firstArgument)))
#endif
#define OS_UNFAIR_LOCK_AVAILABILITY
#ifdef __cplusplus
#define __DARWIN_NULL nullptr
#else
#define __DARWIN_NULL ((void *)0)
#endif
#define __ptrauth_objc_sel
#define __ptrauth_objc_method_list_pointer
#define __ptrauth_objc_method_list_imp
#define __ptrauth_cxx_vtable_pointer
#define ptrauth_key_method_list_pointer ptrauth_key_process_independent_data
#ifndef ptrauth_function_pointer_type_discriminator
#define ptrauth_function_pointer_type_discriminator(type) 0
#endif
static inline int memset_s(void *dest, size_t destSize, int value, size_t count) {
    if (!dest || count > destSize) {
        return 22;
    }
    volatile unsigned char *p = (volatile unsigned char *)dest;
    while (count--) {
        *p++ = (unsigned char)value;
    }
    return 0;
}
#endif
