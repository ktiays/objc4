#pragma once

#include <TargetConditionals.h>
#include <Availability.h>
#include <sys/cdefs.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifndef __unused
#define __unused __attribute__((unused))
#endif
#ifndef __printflike
#define __printflike(formatIndex, firstArgument) \
    __attribute__((format(printf, formatIndex, firstArgument)))
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
#ifndef ptrauth_function_pointer_type_discriminator
#define ptrauth_function_pointer_type_discriminator(type) 0
#endif

static inline int memset_s(void *destination, size_t destinationSize,
                           int value, size_t count) {
    if (!destination || count > destinationSize) { return 22; }
    volatile unsigned char *bytes = (volatile unsigned char *)destination;
    while (count--) { *bytes++ = (unsigned char)value; }
    return 0;
}
