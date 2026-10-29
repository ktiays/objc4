#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <objc/android.h>
#include <assert.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sched.h>
#include <unistd.h>

extern unsigned class_createInstances(Class, size_t, id *, unsigned);
extern void *objc_destructInstance(id);
extern id objc_constructInstance(Class, void *);
extern Class objc_duplicateClass(Class, const char *, size_t);
extern void objc4_test_arc_unload(void);
extern void objc4_android_test_with_runtime_lock(void (*)(void *), void *);

static const char *path = "libobjc4-unload-plugin.so";
static SEL uniqueSelector;
static int associationKey;
static unsigned imageCount(void) {
    unsigned count = 0;
    const char **images = objc_copyImageNames(&count);
    free(images);
    return count;
}
@interface AndroidUnloadHost : NSObject
- (int)value;
@end
@implementation AndroidUnloadHost
- (int)value { return 1; }
@end

static void expect(objc_android_module_result actual, objc_android_module_result wanted) {
    if (actual != wanted) {
        fprintf(stderr, "module result: %s, wanted %s\n", objc_android_module_result_string(actual),
                objc_android_module_result_string(wanted)); abort();
    }
}
static objc_android_module_handle *openModule(void) {
    objc_android_module_handle *handle = NULL;
    expect(objc_android_module_open(path, &handle), OBJC_ANDROID_MODULE_OK);
    assert(handle);
    return handle;
}
static void checkClosed(objc_android_module_handle *handle) {
    expect(objc_android_module_acquire(handle), OBJC_ANDROID_MODULE_CLOSED);
    expect(objc_android_module_close(handle), OBJC_ANDROID_MODULE_CLOSED);
    assert(objc_getClass("AndroidUnloadProbe") == Nil);
    assert(objc_getClass("AndroidUnloadChild") == Nil);
    assert(objc_getClass("AndroidUnloadUnused") == Nil);
    void *mapping = dlopen(path, RTLD_NOW | RTLD_NOLOAD);
    assert(mapping == NULL);
    assert(!strcmp(sel_getName(uniqueSelector), "androidUnloadUniqueSelector_951"));
    assert(sel_registerName("androidUnloadUniqueSelector_951") == uniqueSelector);
    expect(objc_android_module_destroy(handle), OBJC_ANDROID_MODULE_OK);
}
static void cycle(int kind) {
    unsigned before = imageCount();
    objc_android_module_handle *handle = openModule();
    assert(imageCount() == before + 1);
    objc_android_module_handle *duplicate = NULL;
    expect(objc_android_module_open(path, &duplicate), OBJC_ANDROID_MODULE_ALREADY_OPEN);
    assert(!duplicate);
    expect(objc_android_module_acquire(handle), OBJC_ANDROID_MODULE_OK);
    void *symbol = NULL;
    expect(objc_android_module_symbol(handle, "objc4_unload_load_count", &symbol), OBJC_ANDROID_MODULE_OK);
    assert(((int (*)(void))symbol)() == 1);
    expect(objc_android_module_symbol(handle, "objc4_unload_selector", &symbol), OBJC_ANDROID_MODULE_OK);
    uniqueSelector = ((SEL (*)(void))symbol)();
    Class cls = objc_getClass("AndroidUnloadProbe");
    assert(cls);
    const char *imageName = class_getImageName(cls);
    assert(strstr(imageName, path));
    SEL value = sel_registerName("value");
    if (kind == 0) {
        id object = [cls new];
        id child = [objc_getClass("AndroidUnloadChild") new];
        expect(objc_android_module_symbol(handle, "objc4_unload_initialize_count", &symbol), OBJC_ANDROID_MODULE_OK);
        assert(((int (*)(void))symbol)() == 1);
        assert(((int (*)(id, SEL))objc_msgSend)(object, value) == 84);
        expect(objc_android_module_close(handle), OBJC_ANDROID_MODULE_BUSY_LEASES);
        expect(objc_android_module_release(handle), OBJC_ANDROID_MODULE_OK);
        expect(objc_android_module_close(handle), OBJC_ANDROID_MODULE_BUSY_OBJECTS);
        expect(objc_android_module_acquire(handle), OBJC_ANDROID_MODULE_OK);
        [object release];
        [child release];
    } else if (kind == 1) {
        Class child = objc_allocateClassPair(cls, "ExternalUnloadSubclass", 0);
        assert(child); objc_registerClassPair(child);
        expect(objc_android_module_release(handle), OBJC_ANDROID_MODULE_OK);
        expect(objc_android_module_close(handle), OBJC_ANDROID_MODULE_DEPENDENCY);
        expect(objc_android_module_acquire(handle), OBJC_ANDROID_MODULE_OK);
        objc_disposeClassPair(child);
    } else if (kind == 2) {
        Method method = class_getInstanceMethod([AndroidUnloadHost class], value);
        IMP previous = method_setImplementation(method, class_getMethodImplementation(cls, value));
        expect(objc_android_module_release(handle), OBJC_ANDROID_MODULE_OK);
        expect(objc_android_module_close(handle), OBJC_ANDROID_MODULE_DEPENDENCY);
        expect(objc_android_module_acquire(handle), OBJC_ANDROID_MODULE_OK);
        method_setImplementation(method, previous);
    } else if (kind == 3) {
        id object = [NSObject new];
        objc_setAssociatedObject((id)cls, &associationKey, object, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [object release];
        expect(objc_android_module_release(handle), OBJC_ANDROID_MODULE_OK);
        expect(objc_android_module_close(handle), OBJC_ANDROID_MODULE_DEPENDENCY);
        expect(objc_android_module_acquire(handle), OBJC_ANDROID_MODULE_OK);
        objc_removeAssociatedObjects((id)cls);
    } else if (kind == 4) {
        void *storage = calloc(1, class_getInstanceSize(cls));
        id object = objc_constructInstance(cls, storage); assert(object);
        expect(objc_android_module_release(handle), OBJC_ANDROID_MODULE_OK);
        expect(objc_android_module_close(handle), OBJC_ANDROID_MODULE_BUSY_OBJECTS);
        expect(objc_android_module_acquire(handle), OBJC_ANDROID_MODULE_OK);
        objc_destructInstance(object); free(storage);
    } else if (kind == 5) {
        id objects[3]; assert(class_createInstances(cls, 0, objects, 3) == 3);
        id copied = object_copy(objects[0], 0); assert(copied);
        expect(objc_android_module_release(handle), OBJC_ANDROID_MODULE_OK);
        expect(objc_android_module_close(handle), OBJC_ANDROID_MODULE_BUSY_OBJECTS);
        expect(objc_android_module_acquire(handle), OBJC_ANDROID_MODULE_OK);
        for (int i = 0; i < 3; ++i) { [objects[i] release]; }
        [copied release];
    } else if (kind == 6) {
        id object = [NSObject new]; object_setClass(object, cls);
        expect(objc_android_module_release(handle), OBJC_ANDROID_MODULE_OK);
        expect(objc_android_module_close(handle), OBJC_ANDROID_MODULE_BUSY_OBJECTS);
        expect(objc_android_module_acquire(handle), OBJC_ANDROID_MODULE_OK);
        object_setClass(object, [NSObject class]); [object release];
    }
    expect(objc_android_module_release(handle), OBJC_ANDROID_MODULE_OK);
    expect(objc_android_module_close(handle), OBJC_ANDROID_MODULE_OK);
    checkClosed(handle);
    assert(strstr(imageName, path)); // Image-name strings survive descriptor removal.
    assert(imageCount() == before);
}
static void testNativeDependency(void) {
    objc_android_module_handle *base = openModule(), *dependent = NULL;
    expect(objc_android_module_acquire(base), OBJC_ANDROID_MODULE_OK);
    expect(objc_android_module_open("libobjc4-unload-dependent.so", &dependent), OBJC_ANDROID_MODULE_OK);
    expect(objc_android_module_release(base), OBJC_ANDROID_MODULE_OK);
    expect(objc_android_module_close(base), OBJC_ANDROID_MODULE_DEPENDENCY);
    expect(objc_android_module_acquire(base), OBJC_ANDROID_MODULE_OK);
    expect(objc_android_module_close(dependent), OBJC_ANDROID_MODULE_OK);
    expect(objc_android_module_destroy(dependent), OBJC_ANDROID_MODULE_OK);
    assert(objc_getClass("AndroidUnloadDependent") == Nil);
    expect(objc_android_module_release(base), OBJC_ANDROID_MODULE_OK);
    expect(objc_android_module_close(base), OBJC_ANDROID_MODULE_OK);
    checkClosed(base);
}
struct ActiveCall {
    objc_android_module_handle *handle;
    atomic_bool entered, release;
};
static void *activeCall(void *context) {
    struct ActiveCall *call = context;
    expect(objc_android_module_acquire(call->handle), OBJC_ANDROID_MODULE_OK);
    Class cls = objc_getClass("AndroidUnloadProbe");
    SEL selector = sel_registerName("waitUntil:release:");
    assert(((int (*)(id, SEL, atomic_bool *, atomic_bool *))objc_msgSend)(
        (id)cls, selector, &call->entered, &call->release) == 84);
    expect(objc_android_module_release(call->handle), OBJC_ANDROID_MODULE_OK);
    return NULL;
}
static uint64_t now(void) {
    struct timespec time; clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * 1000000000 + time.tv_nsec;
}
static void testActiveCall(void) {
    struct ActiveCall call = {openModule(), false, false};
    pthread_t thread; assert(pthread_create(&thread, NULL, activeCall, &call) == 0);
    uint64_t deadline = now() + 10000000000ULL;
    while (!atomic_load(&call.entered)) { assert(now() < deadline); sched_yield(); }
    expect(objc_android_module_close(call.handle), OBJC_ANDROID_MODULE_BUSY_LEASES);
    atomic_store(&call.release, true);
    assert(pthread_join(thread, NULL) == 0);
    expect(objc_android_module_close(call.handle), OBJC_ANDROID_MODULE_OK);
    checkClosed(call.handle);
}
struct RacingCalls { objc_android_module_handle *handle; atomic_uint calls; };
static void *racingCalls(void *context) {
    struct RacingCalls *race = context;
    for (;;) {
        objc_android_module_result result = objc_android_module_acquire(race->handle);
        if (result == OBJC_ANDROID_MODULE_CLOSED) { return NULL; }
        expect(result, OBJC_ANDROID_MODULE_OK);
        Class cls = objc_getClass("AndroidUnloadProbe"); assert(cls);
        id object = [cls new];
        assert(((int (*)(id, SEL))objc_msgSend)(object, sel_registerName("value")) == 84);
        [object release];
        expect(objc_android_module_release(race->handle), OBJC_ANDROID_MODULE_OK);
        atomic_fetch_add(&race->calls, 1);
    }
}
static void testRacingClose(void) {
    struct RacingCalls race = {openModule(), 0};
    pthread_t threads[4];
    for (int i = 0; i < 4; ++i) { assert(pthread_create(&threads[i], NULL, racingCalls, &race) == 0); }
    uint64_t deadline = now() + 10000000000ULL;
    while (atomic_load(&race.calls) < 1000) { assert(now() < deadline); sched_yield(); }
    for (;;) {
        objc_android_module_result result = objc_android_module_close(race.handle);
        if (result == OBJC_ANDROID_MODULE_OK) { break; }
        expect(result, OBJC_ANDROID_MODULE_BUSY_LEASES);
        assert(now() < deadline); sched_yield();
    }
    for (int i = 0; i < 4; ++i) { assert(pthread_join(threads[i], NULL) == 0); }
    checkClosed(race.handle);
}
static void callbackUnderRuntimeLock(void *context) {
    struct ActiveCall *call = context;
    atomic_store(&call->entered, true);
    uint64_t deadline = now() + 10000000000ULL;
    for (;;) {
        objc_android_module_result result = objc_android_module_acquire(call->handle);
        if (result == OBJC_ANDROID_MODULE_CLOSED) { return; }
        expect(result, OBJC_ANDROID_MODULE_OK);
        expect(objc_android_module_release(call->handle), OBJC_ANDROID_MODULE_OK);
        assert(now() < deadline); sched_yield();
    }
}
static void *runtimeCallback(void *context) {
    objc4_android_test_with_runtime_lock(callbackUnderRuntimeLock, context);
    return NULL;
}
static void testRuntimeLockContention(void) {
    struct ActiveCall call = {openModule(), false, false};
    pthread_t thread; assert(pthread_create(&thread, NULL, runtimeCallback, &call) == 0);
    uint64_t deadline = now() + 10000000000ULL;
    while (!atomic_load(&call.entered)) { assert(now() < deadline); sched_yield(); }
    // A close waiting for runtimeLock must not prevent a callback under that
    // lock from attempting acquire and observing that admission is closed.
    alarm(20);
    for (;;) {
        objc_android_module_result result = objc_android_module_close(call.handle);
        if (result == OBJC_ANDROID_MODULE_OK) { break; }
        expect(result, OBJC_ANDROID_MODULE_BUSY_LEASES);
        assert(now() < deadline); sched_yield();
    }
    assert(pthread_join(thread, NULL) == 0);
    alarm(0);
    checkClosed(call.handle);
}
static int cloneReplacement(id object, SEL selector) { return 7; }
static void testSharedMetaclassRefusal(void) {
    objc_android_module_handle *handle = openModule();
    expect(objc_android_module_acquire(handle), OBJC_ANDROID_MODULE_OK);
    Class cls = objc_getClass("AndroidUnloadProbe");
    Class clone = objc_duplicateClass(cls, "AndroidUnloadHostClone", 0);
    assert(clone);
    unsigned count = 0;
    Method *methods = class_copyMethodList(clone, &count);
    for (unsigned i = 0; i < count; ++i) { method_setImplementation(methods[i], (IMP)cloneReplacement); }
    free(methods);
    expect(objc_android_module_release(handle), OBJC_ANDROID_MODULE_OK);
    // Even with no plugin IMP left in its instance methods, the clone borrows
    // the plugin metaclass. Upstream clones have no reversible public disposal
    // path here, so this final refusal fixture intentionally stays resident.
    expect(objc_android_module_close(handle), OBJC_ANDROID_MODULE_DEPENDENCY);
}
int main(void) {
    @autoreleasepool {
        objc_android_module_handle *handle = NULL;
        expect(objc_android_module_open("libobjc4-test-plugin.so", &handle), OBJC_ANDROID_MODULE_NOT_UNLOADABLE);
        assert(!handle);
        for (int i = 0; i < 56; ++i) { cycle(i % 7); }
        testNativeDependency(); testActiveCall(); testRacingClose(); testRuntimeLockContention(); objc4_test_arc_unload();
        testSharedMetaclassRefusal();
        expect(objc_android_module_open("libobjc4-unload-unsupported.so", &handle), OBJC_ANDROID_MODULE_UNSUPPORTED);
        assert(!handle);
        assert(objc_getProtocol("AndroidUnloadUnsupportedProtocol"));
    }
    puts("PASS: controlled unload/reload, live objects, active/racing leases, dependency refusal, "
         "construct/copy/batch/isa tracking, ARC/weak/exception cleanup, selector lifetime and ELF unmapping");
    return 0;
}
