#include "objc-private.h"
#include <objc/objc-abi.h>
#include <objc/objc-exception.h>
#include <cxxabi.h>
#include <atomic>
#include <exception>

// Apple metadata embeds this layout. libc++abi only requires the std::type_info
// prefix and the __shim_type_info virtual functions for exception matching.
struct objc_typeinfo {
    const void **vtable;
    const char *name;
    Class cls_unremapped;
};

namespace {
struct Exception {
    id object;
    objc_typeinfo type;
};

id preprocess(id object) { return object; }
int matches(Class expected, id object) {
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        if (cls == expected) { return 1; }
    }
    return 0;
}
void uncaught(id) {}
std::atomic<objc_exception_preprocessor> preprocessor{preprocess};
std::atomic<objc_exception_matcher> matcher{matches};
std::atomic<objc_uncaught_exception_handler> uncaughtHandler{uncaught};
std::terminate_handler previousTerminate;

void typeInfoNoop(void *) {}
void *typeInfoDestroy(void *pointer) { return pointer; }
// C++ class RTTI probes must reject these synthetic ObjC types. The callbacks
// leave libc++abi's search state unchanged, which reports no C++ base match.
void searchAbove(const void *, void *, const void *, const void *, int, bool) {}
void searchBelow(const void *, void *, const void *, int, bool) {}
void publicBase(const void *, void *, void *, int) {}
bool canCatch(const objc_typeinfo *expected, const objc_typeinfo *thrown,
              void **adjusted) {
    if (thrown->vtable != objc_ehtype_vtable + 2) { return false; }
    id object = static_cast<Exception *>(*adjusted)->object;
    if (expected != &OBJC_EHTYPE_id) {
        Class cls = _class_remap(expected->cls_unremapped);
        if (!cls || !matcher.load()(cls, object)) { return false; }
    }
    *adjusted = object;
    return true;
}
void __attribute__((thiscall)) destroyException(void *pointer) {
    objc_release(static_cast<Exception *>(pointer)->object);
}
void terminateException() {
    if (__cxxabiv1::__cxa_current_exception_type()) {
        @try {
            __cxxabiv1::__cxa_rethrow();
        } @catch (id object) {
            uncaughtHandler.load()(object);
        } @catch (...) {
        }
    }
    previousTerminate();
    abort();
}
}

// These entries use the libc++abi type_info vtable layout.
const void *objc_ehtype_vtable[] = {
    nullptr, &OBJC_EHTYPE_id,
    reinterpret_cast<const void *>(typeInfoDestroy),
    reinterpret_cast<const void *>(typeInfoDestroy),
    reinterpret_cast<const void *>(typeInfoNoop),
    reinterpret_cast<const void *>(typeInfoNoop),
    reinterpret_cast<const void *>(canCatch),
    reinterpret_cast<const void *>(searchAbove),
    reinterpret_cast<const void *>(searchBelow),
    reinterpret_cast<const void *>(publicBase)
};
objc_typeinfo OBJC_EHTYPE_id = {objc_ehtype_vtable + 2, "id", Nil};

void objc_exception_throw(id object) {
    object = preprocessor.load()(object);
    auto *exception = static_cast<Exception *>(
        __cxxabiv1::__cxa_allocate_exception(sizeof(Exception)));
    exception->object = objc_retain(object);
    exception->type = {objc_ehtype_vtable + 2, object_getClassName(object),
                       object_getClass(object)};
    __cxxabiv1::__cxa_throw(exception,
        reinterpret_cast<std::type_info *>(&exception->type), destroyException);
}
void objc_exception_rethrow() { __cxxabiv1::__cxa_rethrow(); }
id objc_begin_catch(void *exception) {
    return (id)__cxxabiv1::__cxa_begin_catch(exception);
}
void objc_end_catch() { __cxxabiv1::__cxa_end_catch(); }
void objc_terminate() { std::terminate(); }
objc_exception_preprocessor objc_setExceptionPreprocessor(objc_exception_preprocessor fn) {
    return preprocessor.exchange(fn);
}
objc_exception_matcher objc_setExceptionMatcher(objc_exception_matcher fn) {
    return matcher.exchange(fn);
}
objc_uncaught_exception_handler objc_setUncaughtExceptionHandler(objc_uncaught_exception_handler fn) {
    return uncaughtHandler.exchange(fn);
}
void exception_init() { previousTerminate = std::set_terminate(terminateException); }
void _destroyAltHandlerList(struct alt_handler_list *) {}
ExplicitInitLock<mutex_t> AltHandlerDebugLock;

// LLVM's MinGW backend lowers the Apple personality to a Windows SEH handler.
// libc++abi performs the C++/Objective-C type_info matching above.
extern "C" EXCEPTION_DISPOSITION __gxx_personality_seh0(
    PEXCEPTION_RECORD, void *, PCONTEXT, PDISPATCHER_CONTEXT);
extern "C" EXCEPTION_DISPOSITION objc_windows_personality(
    PEXCEPTION_RECORD, void *, PCONTEXT, PDISPATCHER_CONTEXT) __asm__("__objc_personality_v0");
extern "C" EXCEPTION_DISPOSITION objc_windows_personality(
    PEXCEPTION_RECORD record, void *frame, PCONTEXT context,
    PDISPATCHER_CONTEXT dispatcher) {
    return __gxx_personality_seh0(record, frame, context, dispatcher);
}
