#include "objc-private.h"
#include "objc-cache-android.h"
#include <sched.h>

static_assert(CACHE_MASK_STORAGE == CACHE_MASK_STORAGE_OUTLINED);
static_assert(CACHE_IMP_ENCODING == CACHE_IMP_ENCODING_ISA_XOR);
static_assert(SEL_HASH_SHIFT_XOR == 1);
static_assert(sizeof(mask_t) == 4 && sizeof(bucket_t) == 16);
static_assert(sizeof(objc_android_cache_shard) == 64);
static_assert(offsetof(objc_class, cache) == OBJC_ANDROID_CACHE_BUCKETS_OFFSET);

extern "C" {
__attribute__((visibility("hidden")))
objc_android_cache_shard objc_android_cache_shards[1 << OBJC_ANDROID_CACHE_SHARD_BITS] = {};
}

static constexpr uint32_t writerBit = uint32_t(1) << OBJC_ANDROID_CACHE_WRITER_BIT;
static objc_android_cache_shard &shardFor(const void *cls) {
    return objc_android_cache_shards[(uintptr_t(cls) >> 4) & ((1 << OBJC_ANDROID_CACHE_SHARD_BITS) - 1)];
}

// Readers never call Objective-C or acquire runtimeLock while holding a shard.
// Writers close admission before waiting, so a stream of readers cannot starve
// reclamation. A reader that sees a writer simply takes the ordinary slow path.
static bool readBegin(objc_android_cache_shard &shard) {
    uint32_t value = __atomic_load_n(&shard.state, __ATOMIC_RELAXED);
    do {
        if (value & writerBit) { return false; }
    } while (!__atomic_compare_exchange_n(&shard.state, &value, value + 1,
                                          true, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED));
    return true;
}
static void readEnd(objc_android_cache_shard &shard) {
    __atomic_fetch_sub(&shard.state, 1, __ATOMIC_RELEASE);
}

void objc_android_cache_write_begin(const void *cls) {
    auto &shard = shardFor(cls);
    uint32_t value = __atomic_load_n(&shard.state, __ATOMIC_RELAXED);
    for (;;) {
        if (!(value & writerBit) &&
            __atomic_compare_exchange_n(&shard.state, &value, value | writerBit,
                                        false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
            break;
        }
        sched_yield();
        value = __atomic_load_n(&shard.state, __ATOMIC_RELAXED);
    }
    while (__atomic_load_n(&shard.state, __ATOMIC_ACQUIRE) != writerBit) {
        sched_yield();
    }
}
void objc_android_cache_write_end(const void *cls) {
    __atomic_store_n(&shardFor(cls).state, 0, __ATOMIC_RELEASE);
}

extern "C" IMP cache_getImp(Class cls, SEL sel, IMP) {
#if OBJC_ANDROID_CACHE_FASTPATH
    if (!cls) { return nullptr; }
    auto &shard = shardFor(cls);
    if (!readBegin(shard)) { return nullptr; }
    IMP result = nullptr;
    auto buckets = cls->cache.buckets();
    auto capacity = cls->cache.capacity();
    if (buckets && capacity) {
        mask_t mask = capacity - 1;
        uintptr_t hash = uintptr_t(sel) ^ (uintptr_t(sel) >> 7);
        mask_t index = hash & mask;
        for (unsigned remaining = capacity; remaining; --remaining) {
            auto key = buckets[index].sel();
            if (key == sel) { result = buckets[index].imp(buckets, cls); break; }
            if (!key) { break; }
            index = (index - 1) & mask;
        }
    }
    readEnd(shard);
    return result;
#else
    return nullptr;
#endif
}

#if OBJC_ANDROID_TESTING
static uint64_t reclaimedCount;
static uint64_t reclaimedBytes;
void objc_android_cache_record_reclaim(size_t bytes) {
    __atomic_fetch_add(&reclaimedCount, 1, __ATOMIC_RELAXED);
    __atomic_fetch_add(&reclaimedBytes, bytes, __ATOMIC_RELAXED);
}
extern "C" __attribute__((visibility("default")))
void objc4_android_test_cache_reclaimed(uint64_t *count, uint64_t *bytes) {
    *count = __atomic_load_n(&reclaimedCount, __ATOMIC_RELAXED);
    *bytes = __atomic_load_n(&reclaimedBytes, __ATOMIC_RELAXED);
}
extern "C" __attribute__((visibility("default")))
void objc4_android_test_with_cache_reader(Class cls, void (*body)(void *), void *context) {
    auto &shard = shardFor(cls);
    while (!readBegin(shard)) { sched_yield(); }
    body(context);
    readEnd(shard);
}
extern "C" __attribute__((visibility("default")))
bool objc4_android_test_cache_writer_pending(Class cls) {
    return __atomic_load_n(&shardFor(cls).state, __ATOMIC_ACQUIRE) & writerBit;
}
#else
void objc_android_cache_record_reclaim(size_t) {}
#endif
