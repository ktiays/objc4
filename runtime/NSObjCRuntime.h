/*	NSObjCRuntime.h
	Copyright (c) 1994-2012, Apple Inc. All rights reserved.
*/

#ifndef _OBJC_NSOBJCRUNTIME_H_
#define _OBJC_NSOBJCRUNTIME_H_

#include <TargetConditionals.h>
#include <limits.h>
#include <objc/objc.h>

#if defined(_WIN64)
typedef intptr_t NSInteger;
typedef uintptr_t NSUInteger;
#elif (__SIZEOF_POINTER__ == 8) || NS_BUILD_32_LIKE_64
typedef long NSInteger;
typedef unsigned long NSUInteger;
#else
typedef int NSInteger;
typedef unsigned int NSUInteger;
#endif

#if defined(_WIN64)
#define NSIntegerMax    INTPTR_MAX
#define NSIntegerMin    INTPTR_MIN
#define NSUIntegerMax   UINTPTR_MAX
#else
#define NSIntegerMax    LONG_MAX
#define NSIntegerMin    LONG_MIN
#define NSUIntegerMax   ULONG_MAX
#endif

#define NSINTEGER_DEFINED 1

#ifndef NS_DESIGNATED_INITIALIZER
#if __has_attribute(objc_designated_initializer)
#define NS_DESIGNATED_INITIALIZER __attribute__((objc_designated_initializer))
#else
#define NS_DESIGNATED_INITIALIZER
#endif
#endif

#endif
