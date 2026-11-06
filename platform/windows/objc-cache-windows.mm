#include "objc-private.h"
#include "objc-cache-windows.h"
#include <windows.h>

namespace {
struct alignas(64) CacheShard { uint32_t state; };
CacheShard shards[256] = {};
constexpr uint32_t writerBit = uint32_t(1) << 31;

CacheShard &shardFor(const void *cls) {
    return shards[(uintptr_t(cls) >> 4) & 255];
}

bool readBegin(CacheShard &shard) {
    uint32_t state = __atomic_load_n(&shard.state, __ATOMIC_RELAXED);
    do {
        if (state & writerBit) { return false; }
    } while (!__atomic_compare_exchange_n(&shard.state, &state, state + 1,
                                          true, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED));
    return true;
}
}

void objc_windows_cache_write_begin(const void *cls) {
    auto &shard = shardFor(cls);
    uint32_t state = __atomic_load_n(&shard.state, __ATOMIC_RELAXED);
    for (;;) {
        if (!(state & writerBit) &&
            __atomic_compare_exchange_n(&shard.state, &state, state | writerBit,
                                        false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
            break;
        }
        SwitchToThread();
        state = __atomic_load_n(&shard.state, __ATOMIC_RELAXED);
    }
    while (__atomic_load_n(&shard.state, __ATOMIC_ACQUIRE) != writerBit) {
        SwitchToThread();
    }
}

void objc_windows_cache_write_end(const void *cls) {
    __atomic_store_n(&shardFor(cls).state, 0, __ATOMIC_RELEASE);
}

extern "C" IMP cache_getImp(Class cls, SEL selector, IMP) {
    if (!cls) { return nullptr; }
    auto &shard = shardFor(cls);
    if (!readBegin(shard)) { return nullptr; }
    IMP result = nullptr;
    auto buckets = cls->cache.buckets();
    unsigned capacity = cls->cache.capacity();
    if (buckets && capacity) {
        mask_t mask = capacity - 1;
        uintptr_t hash = uintptr_t(selector);
#if SEL_HASH_SHIFT_XOR
        hash ^= hash >> 7;
#endif
        mask_t index = hash & mask;
        for (unsigned remaining = capacity; remaining; --remaining) {
            auto key = buckets[index].sel();
            if (key == selector) { result = buckets[index].imp(buckets, cls); break; }
            if (!key) { break; }
#if __arm64__
            index = (index - 1) & mask;
#else
            index = (index + 1) & mask;
#endif
        }
    }
    __atomic_fetch_sub(&shard.state, 1, __ATOMIC_RELEASE);
    return result;
}
