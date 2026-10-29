#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <sched.h>
#include <time.h>

// Test-only exports are omitted when OBJC_BUILD_ANDROID_TESTS=OFF.
extern void objc4_android_test_cache_reclaimed(uint64_t *, uint64_t *);
extern void objc4_android_test_with_cache_reader(Class, void (*)(void *), void *);
extern bool objc4_android_test_cache_writer_pending(Class);
extern void _objc_flush_caches(Class);

@interface CacheProbe : NSObject
- (int)value;
@end
@implementation CacheProbe
- (int)value { return 1; }
@end

static int valueA(id object, SEL selector) { return 1; }
static int valueB(id object, SEL selector) { return 2; }
#define VALUE_METHOD(N) static int value##N(id object, SEL selector) { return N; }
VALUE_METHOD(0) VALUE_METHOD(1) VALUE_METHOD(2) VALUE_METHOD(3)
VALUE_METHOD(4) VALUE_METHOD(5) VALUE_METHOD(6) VALUE_METHOD(7)
static IMP values[] = {(IMP)value0, (IMP)value1, (IMP)value2, (IMP)value3,
                       (IMP)value4, (IMP)value5, (IMP)value6, (IMP)value7};

static CacheProbe *probe;
static Class cacheProbeClass;
static Method valueMethod;
static atomic_bool readerEntered, releaseReader, mutationDone, stopReaders;
static atomic_ullong readerCalls;

static uint64_t now(void) {
    struct timespec time;
    assert(clock_gettime(CLOCK_MONOTONIC, &time) == 0);
    return (uint64_t)time.tv_sec * 1000000000 + time.tv_nsec;
}
static void waitFlag(atomic_bool *flag) {
    uint64_t deadline = now() + 10000000000ULL;
    while (!atomic_load(flag)) { assert(now() < deadline); sched_yield(); }
}
static void holdReader(void *context) {
    atomic_store(&readerEntered, true);
    waitFlag(&releaseReader);
}
static void *blockedReader(void *context) {
    objc4_android_test_with_cache_reader(cacheProbeClass, holdReader, NULL);
    return NULL;
}
static void *oneMutation(void *context) {
    method_setImplementation(valueMethod, (IMP)valueB);
    atomic_store(&mutationDone, true);
    return NULL;
}
static void *stressReader(void *context) {
    uint64_t calls = 0;
    while (!atomic_load_explicit(&stopReaders, memory_order_relaxed)) {
        int value = [probe value];
        assert(value == 1 || value == 2);
        ++calls;
    }
    atomic_fetch_add(&readerCalls, calls);
    return NULL;
}

int main(void) {
    @autoreleasepool {
        probe = [CacheProbe new];
        cacheProbeClass = [CacheProbe class];
        valueMethod = class_getInstanceMethod(cacheProbeClass, @selector(value));
        assert([probe value] == 1);

        // Force collisions, complete small caches, probe wraparound, and growth.
        Class dynamic = objc_allocateClassPair([NSObject class], "AndroidCacheGrowth", 0);
        assert(dynamic);
        enum { methodCount = 192 };
        SEL selectors[methodCount];
        for (int i = 0; i < methodCount; ++i) {
            char name[64]; snprintf(name, sizeof(name), "cacheGrowthMethod_%d", i);
            selectors[i] = sel_registerName(name);
            assert(class_addMethod(dynamic, selectors[i], values[i % 8], "i@:"));
        }
        objc_registerClassPair(dynamic);
        {
            id instance = [dynamic new];
            for (int pass = 0; pass < 8; ++pass) {
                for (int i = 0; i < methodCount; ++i) {
                    assert(((int (*)(id, SEL))objc_msgSend)(instance, selectors[i]) == i % 8);
                }
            }
        }
        objc_disposeClassPair(dynamic);

        // A writer must wait for a reader already inside its cache, rather
        // than freeing the old array as soon as it is detached.
        uint64_t beforeCount, beforeBytes, afterCount, afterBytes;
        objc4_android_test_cache_reclaimed(&beforeCount, &beforeBytes);
        pthread_t reader, writer;
        assert(pthread_create(&reader, NULL, blockedReader, NULL) == 0);
        waitFlag(&readerEntered);
        assert(pthread_create(&writer, NULL, oneMutation, NULL) == 0);
        uint64_t deadline = now() + 10000000000ULL;
        while (!objc4_android_test_cache_writer_pending(cacheProbeClass)) {
            assert(now() < deadline); sched_yield();
        }
        assert(!atomic_load(&mutationDone));
        objc4_android_test_cache_reclaimed(&afterCount, &afterBytes);
        assert(afterCount == beforeCount && afterBytes == beforeBytes);
        atomic_store(&releaseReader, true);
        assert(pthread_join(reader, NULL) == 0);
        assert(pthread_join(writer, NULL) == 0);
        assert([probe value] == 2);
        objc4_android_test_cache_reclaimed(&afterCount, &afterBytes);
        assert(afterCount > beforeCount && afterBytes > beforeBytes);

        enum { threadCount = 4, mutations = 10000 };
        pthread_t readers[threadCount];
        for (int i = 0; i < threadCount; ++i) {
            assert(pthread_create(&readers[i], NULL, stressReader, NULL) == 0);
        }
        beforeCount = afterCount; beforeBytes = afterBytes;
        for (int i = 0; i < mutations; ++i) {
            method_setImplementation(valueMethod, i % 2 ? (IMP)valueA : (IMP)valueB);
            assert([probe value] == (i % 2 ? 1 : 2));
        }
        atomic_store(&stopReaders, true);
        for (int i = 0; i < threadCount; ++i) { assert(pthread_join(readers[i], NULL) == 0); }
        objc4_android_test_cache_reclaimed(&afterCount, &afterBytes);
        assert(afterCount >= beforeCount + mutations);
        assert(afterBytes >= beforeBytes + mutations * 32);
        assert(atomic_load(&readerCalls) > 0);
        _objc_flush_caches(Nil);
        assert([probe value] == 1);
        printf("PASS: cache growth/collisions, blocked-reader reclamation, %d concurrent swizzles, "
               "%llu reader calls, reclaimed %llu arrays / %llu bytes\n", mutations,
               atomic_load(&readerCalls), (unsigned long long)(afterCount - beforeCount),
               (unsigned long long)(afterBytes - beforeBytes));
        probe = nil;
    }
    return 0;
}
