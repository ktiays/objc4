#pragma once

// Shared by the AAPCS64 dispatcher and C++ cache writers. Layout is checked
// against upstream cache_t/bucket_t when compiling the Android backend.
#define OBJC_ANDROID_CACHE_BUCKETS_OFFSET 16
#define OBJC_ANDROID_CACHE_MASK_OFFSET 24
#define OBJC_ANDROID_CACHE_SHARD_BITS 8
#define OBJC_ANDROID_CACHE_SHARD_SHIFT 6
#define OBJC_ANDROID_CACHE_WRITER_BIT 31

#ifndef __ASSEMBLER__
#include <stdint.h>
#include <stddef.h>

struct alignas(1 << OBJC_ANDROID_CACHE_SHARD_SHIFT) objc_android_cache_shard {
    uint32_t state;
};

extern "C" {
extern objc_android_cache_shard objc_android_cache_shards[1 << OBJC_ANDROID_CACHE_SHARD_BITS];
void objc_android_cache_write_begin(const void *cls);
void objc_android_cache_write_end(const void *cls);
void objc_android_cache_record_reclaim(size_t bytes);
}

class objc_android_cache_writer {
    const void *cls;
public:
    explicit objc_android_cache_writer(const void *cls) : cls(cls) {
        objc_android_cache_write_begin(cls);
    }
    ~objc_android_cache_writer() { objc_android_cache_write_end(cls); }
    objc_android_cache_writer(const objc_android_cache_writer &) = delete;
    objc_android_cache_writer &operator=(const objc_android_cache_writer &) = delete;
};
#endif
