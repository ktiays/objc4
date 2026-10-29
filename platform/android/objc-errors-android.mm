#include "objc-private.h"
#include <android/log.h>
#include <stdarg.h>
#include <execinfo.h>

ExplicitInitLock<mutex_t> crashlog_lock;

static void logMessage(int priority, const char *format, va_list args) {
    char message[2048];
    vsnprintf(message, sizeof(message), format, args);
    __android_log_write(priority, "objc4", message);
    dprintf(STDERR_FILENO, "objc[%d]: %s\n", getpid(), message);
}

#define LOG_FUNCTION(name, priority) \
    void name(const char *format, ...) { \
        va_list args; va_start(args, format); \
        logMessage(priority, format, args); va_end(args); \
    }
LOG_FUNCTION(_objc_inform, ANDROID_LOG_INFO)
LOG_FUNCTION(_objc_inform_on_crash, ANDROID_LOG_ERROR)
LOG_FUNCTION(_objc_inform_now_and_on_crash, ANDROID_LOG_ERROR)
LOG_FUNCTION(_objc_fault, ANDROID_LOG_ERROR)
LOG_FUNCTION(_objc_fault_and_log, ANDROID_LOG_ERROR)
LOG_FUNCTION(_objc_stochastic_fault, ANDROID_LOG_ERROR)
#undef LOG_FUNCTION

void _objc_fatal(const char *format, ...) {
    va_list args; va_start(args, format);
    logMessage(ANDROID_LOG_FATAL, format, args); va_end(args);
    if (DebugDontCrash) { _Exit(1); }
    abort();
}
void _objc_fatal_with_reason(uint64_t, uint64_t, const char *format, ...) {
    va_list args; va_start(args, format);
    logMessage(ANDROID_LOG_FATAL, format, args); va_end(args);
    abort();
}
__attribute__((noreturn))
void _objc_error(id self, const char *format, va_list args) {
    logMessage(ANDROID_LOG_FATAL, format, args);
    _objc_fatal("runtime error for object %p", self);
}
void __objc_error(id self, const char *format, ...) {
    va_list args; va_start(args, format);
    _objc_error(self, format, args);
}
void _objc_inform_deprecated(const char *oldName, const char *newName) {
    _objc_inform("Deprecated runtime API %s; replacement: %s", oldName,
                 newName ? newName : "none");
}
void _objc_inform_backtrace(const char *prefix) {
    void *frames[64];
    int count = backtrace(frames, 64);
    _objc_inform("%s", prefix);
    backtrace_symbols_fd(frames, count, STDERR_FILENO);
}
