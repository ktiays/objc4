#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <pthread.h>
#include <stdatomic.h>
#include <dlfcn.h>
#include <stdarg.h>

static int loads;
static int initializes;
static atomic_int deallocations;
extern uintptr_t _objc_rootRetainCount(id object);

struct LargeResult { uint64_t values[5]; };
struct FloatingResult { double values[4]; };

@interface AndroidProbe : NSObject
@property(nonatomic, strong) id child;
- (uint64_t)add:(uint64_t)a to:(uint64_t)b;
- (double)mix:(double)a with:(double)b;
- (struct LargeResult)large:(uint64_t)value;
- (struct FloatingResult)floating:(double)value;
- (int)sum:(int)count, ...;
@end

@implementation AndroidProbe
+ (void)load { ++loads; }
+ (void)initialize { if (self == objc_getClass("AndroidProbe")) { ++initializes; } }
- (uint64_t)add:(uint64_t)a to:(uint64_t)b { return a + b; }
- (double)mix:(double)a with:(double)b { return a * 2.0 + b; }
- (struct LargeResult)large:(uint64_t)value {
    return (struct LargeResult){{value, value + 1, value + 2, value + 3, value + 4}};
}
- (struct FloatingResult)floating:(double)value {
    return (struct FloatingResult){{value, value + 1, value + 2, value + 3}};
}
- (int)sum:(int)count, ... {
    va_list args; va_start(args, count);
    int result = 0;
    for (int i = 0; i < count; ++i) { result += va_arg(args, int); }
    va_end(args);
    return result;
}
- (void)dealloc { atomic_fetch_add(&deallocations, 1); }
@end

@protocol AndroidProbeProtocol
- (int)categoryValue;
@end
@interface AndroidProbe (AndroidCategory) <AndroidProbeProtocol>
@end
@implementation AndroidProbe (AndroidCategory)
- (int)categoryValue { return 73; }
@end

@interface AndroidChild : AndroidProbe
@end

static uint64_t replacementAdd(id object, SEL selector, uint64_t a, uint64_t b) {
    return a + b + 100;
}
static int dynamicValue(id object, SEL selector) { return 64; }
static void *threadMain(void *unused) {
    for (int i = 0; i < 100; ++i) {
        @autoreleasepool {
            AndroidProbe *probe = [AndroidProbe new];
            __weak id weak = probe;
            assert([probe add:20 to:22] == 42);
            probe = nil;
            assert(weak == nil);
        }
    }
    return NULL;
}
@implementation AndroidChild
- (uint64_t)add:(uint64_t)a to:(uint64_t)b { return [super add:a to:b] + 10; }
@end

int main(void) {
    printf("objc4 Android arm64 smoke: starting\n");
    fflush(stdout);
    assert(loads == 1);
    __weak AndroidProbe *weak;
    @autoreleasepool {
        AndroidProbe *probe = [AndroidProbe new];
        assert(_objc_rootRetainCount(probe) == 1);
        assert(initializes == 1);
        assert([probe add:12 to:30] == 42);
        assert([probe mix:1.25 with:2.5] == 5.0);
        assert([probe categoryValue] == 73);
        assert(class_conformsToProtocol([AndroidProbe class], @protocol(AndroidProbeProtocol)));
        struct LargeResult result = [probe large:40];
        for (int i = 0; i < 5; ++i) { assert(result.values[i] == 40 + i); }
        struct FloatingResult floating = [probe floating:3.5];
        for (int i = 0; i < 4; ++i) { assert(floating.values[i] == 3.5 + i); }
        assert(([probe sum:10, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10] == 55));
        assert([[AndroidChild new] add:12 to:30] == 52);
        AndroidProbe *missing = nil;
        assert([missing add:1 to:2] == 0);
        assert([missing mix:1 with:2] == 0.0);
        struct LargeResult nilLarge = [missing large:1];
        for (int i = 0; i < 5; ++i) { assert(nilLarge.values[i] == 0); }
        struct FloatingResult nilFloating = [missing floating:1];
        for (int i = 0; i < 4; ++i) { assert(nilFloating.values[i] == 0); }

        Method method = class_getInstanceMethod([AndroidProbe class], @selector(add:to:));
        IMP previous = method_setImplementation(method, (IMP)replacementAdd);
        assert([probe add:12 to:30] == 142);
        method_setImplementation(method, previous);
        assert([probe add:12 to:30] == 42);

        int caught = 0;
        @try { @throw probe; }
        @catch (AndroidProbe *exception) { assert(exception == probe); caught = 1; }
        @finally { assert(caught == 1); }

        weak = probe;
        assert(weak == probe);
        probe.child = [AndroidProbe new];
        assert(probe.child != nil);
        probe.child = nil;
        probe = nil;
    }
    assert(weak == nil);
    assert(atomic_load(&deallocations) >= 3);

    __weak AndroidProbe *captured;
    uint64_t (^block)(uint64_t);
    @autoreleasepool {
        AndroidProbe *owner = [AndroidProbe new];
        captured = owner;
        block = ^uint64_t(uint64_t value) { return [owner add:value to:2]; };
        owner = nil;
        assert(captured != nil);
        assert(block(40) == 42);
    }
    assert(captured != nil);
    block = nil;
    assert(captured == nil);
    pthread_t threads[4];
    int before = atomic_load(&deallocations);
    for (int i = 0; i < 4; ++i) { assert(pthread_create(&threads[i], NULL, threadMain, NULL) == 0); }
    for (int i = 0; i < 4; ++i) { assert(pthread_join(threads[i], NULL) == 0); }
    assert(atomic_load(&deallocations) == before + 400);
    Class dynamicClass = objc_allocateClassPair([NSObject class], "AndroidDynamic", 0);
    assert(dynamicClass);
    SEL dynamicSelector = sel_registerName("dynamicValue");
    assert(class_addMethod(dynamicClass, dynamicSelector, (IMP)dynamicValue, "i@:"));
    objc_registerClassPair(dynamicClass);
    @autoreleasepool {
        id object = [dynamicClass new];
        assert(((int (*)(id, SEL))objc_msgSend)(object, dynamicSelector) == 64);
    }
    objc_disposeClassPair(dynamicClass);
    assert(objc_getClass("AndroidDynamic") == Nil);
    assert(objc_getClass("AndroidPlugin") == Nil);
    void *plugin = dlopen("libobjc4-test-plugin.so", RTLD_NOW | RTLD_LOCAL);
    if (!plugin) { fprintf(stderr, "dlopen: %s\n", dlerror()); }
    assert(plugin);
    int (*pluginLoads)(void) = (int (*)(void))dlsym(plugin, "objc4_android_plugin_load_count");
    assert(pluginLoads && pluginLoads() == 1);
    @autoreleasepool {
        Class pluginClass = objc_getClass("AndroidPlugin");
        assert(pluginClass != Nil);
        id object = [pluginClass new];
        SEL value = sel_registerName("value");
        assert(((int (*)(id, SEL))objc_msgSend)(object, value) == 42);
        assert(dlclose(plugin) == 0);
        assert(((int (*)(id, SEL))objc_msgSend)(object, value) == 42);
    }
    puts("PASS: load/initialize, integer/FP/large-struct dispatch, super, nil, ARC, properties, weak, pools, category, protocol, swizzle, exception/finally, Blocks, 4-thread lifetime stress, dlopen and pinned image lifetime");
    return 0;
}
