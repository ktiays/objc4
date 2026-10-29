#pragma once
#include <TargetConditionals.h>

// Apple OS availability does not restrict Android declarations.
#define __OSX_AVAILABLE(...)
#define __IOS_AVAILABLE(...)
#define __TVOS_AVAILABLE(...)
#define __WATCHOS_AVAILABLE(...)
#define __BRIDGEOS_AVAILABLE(...)
#define __OSX_AVAILABLE_STARTING(...)
#define __OSX_DEPRECATED(...)
#define __IOS_DEPRECATED(...)
#define __TVOS_DEPRECATED(...)
#define __WATCHOS_DEPRECATED(...)
#define __BRIDGEOS_DEPRECATED(...)
#define __OSX_UNAVAILABLE
#define __IOS_UNAVAILABLE
#define __TVOS_UNAVAILABLE
#define __WATCHOS_UNAVAILABLE
#define __BRIDGEOS_UNAVAILABLE
#define __API_AVAILABLE(...)
#define __API_DEPRECATED(...)
#define __API_UNAVAILABLE(...)
#define API_AVAILABLE(...)
#define API_UNAVAILABLE(...)
#ifndef UNAVAILABLE_ATTRIBUTE
#define UNAVAILABLE_ATTRIBUTE __attribute__((unavailable))
#endif
