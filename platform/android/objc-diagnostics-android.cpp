#include <execinfo.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <unwind.h>

namespace {
struct Trace { void **buffer; int count; int capacity; };
_Unwind_Reason_Code traceFrame(_Unwind_Context *frame, void *opaque) {
    auto trace = static_cast<Trace *>(opaque);
    if (trace->count == trace->capacity) { return _URC_END_OF_STACK; }
    uintptr_t pc = _Unwind_GetIP(frame);
    if (pc) { trace->buffer[trace->count++] = reinterpret_cast<void *>(pc); }
    return _URC_NO_REASON;
}
}
extern "C" int backtrace(void **buffer, int capacity) {
    if (capacity <= 0) { return 0; }
    Trace trace{buffer, 0, capacity};
    _Unwind_Backtrace(traceFrame, &trace);
    return trace.count;
}
extern "C" void backtrace_symbols_fd(void *const *buffer, int count, int fd) {
    for (int i = 0; i < count; ++i) {
        Dl_info info{};
        dladdr(buffer[i], &info);
        dprintf(fd, "%p %s %s\n", buffer[i], info.dli_fname ? info.dli_fname : "?",
                 info.dli_sname ? info.dli_sname : "?");
    }
}
