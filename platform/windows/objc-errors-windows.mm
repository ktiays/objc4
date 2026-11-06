#include "objc-private.h"
#include <windows.h>
#include <stdarg.h>

ExplicitInitLock<mutex_t> crashlog_lock;

static void logMessage(const char *format, va_list arguments) {
    fputs("objc4: ", stderr);
    vfprintf(stderr, format, arguments);
    fputc('\n', stderr);
}

#define LOG_FUNCTION(name) \
    void name(const char *format, ...) { \
        va_list arguments; va_start(arguments, format); \
        logMessage(format, arguments); va_end(arguments); \
    }
LOG_FUNCTION(_objc_inform)
LOG_FUNCTION(_objc_inform_on_crash)
LOG_FUNCTION(_objc_inform_now_and_on_crash)
LOG_FUNCTION(_objc_fault)
LOG_FUNCTION(_objc_fault_and_log)
LOG_FUNCTION(_objc_stochastic_fault)
#undef LOG_FUNCTION

void _objc_fatal(const char *format, ...) {
    va_list arguments; va_start(arguments, format);
    logMessage(format, arguments); va_end(arguments);
    abort();
}
void _objc_fatal_with_reason(uint64_t, uint64_t, const char *format, ...) {
    va_list arguments; va_start(arguments, format);
    logMessage(format, arguments); va_end(arguments);
    abort();
}
__attribute__((noreturn))
void _objc_error(id object, const char *format, va_list arguments) {
    logMessage(format, arguments);
    _objc_fatal("runtime error for object %p", object);
}
void __objc_error(id object, const char *format, ...) {
    va_list arguments; va_start(arguments, format);
    _objc_error(object, format, arguments);
}
void _objc_inform_deprecated(const char *oldName, const char *newName) {
    _objc_inform("Deprecated runtime API %s; replacement: %s", oldName,
                 newName ? newName : "none");
}
void _objc_inform_backtrace(const char *prefix) {
    _objc_inform("%s", prefix);
    void *frames[32];
    USHORT count = CaptureStackBackTrace(0, 32, frames, nullptr);
    for (USHORT index = 0; index < count; ++index) {
        _objc_inform("  %p", frames[index]);
    }
}
