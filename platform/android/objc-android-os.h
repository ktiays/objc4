#pragma once

#include <dlfcn.h>
#include <malloc.h>
#include <time.h>
#include <mach-o/loader.h>
#include "Threading/threading.h"

using spinlock_t = objc_lock_t;
using mutex_t = objc_lock_t;
using recursive_mutex_t = objc_recursive_lock_t;
using mutex_locker_t = mutex_t::locker;
using conditional_mutex_locker_t = mutex_t::conditional_locker;
using headerType = mach_header;
using uuid_t = unsigned char[16];

// These identifiers describe ObjC metadata, independently of the object format.
enum _dyld_section_location_kind {
    _dyld_section_location_data_sel_refs,
    _dyld_section_location_data_msg_refs,
    _dyld_section_location_data_class_refs,
    _dyld_section_location_data_super_refs,
    _dyld_section_location_data_protocol_refs,
    _dyld_section_location_data_class_list,
    _dyld_section_location_data_non_lazy_class_list,
    _dyld_section_location_data_stub_list,
    _dyld_section_location_data_category_list,
    _dyld_section_location_data_category_list2,
    _dyld_section_location_data_non_lazy_category_list,
    _dyld_section_location_data_protocol_list,
    _dyld_section_location_data_objc_fork_ok,
    _dyld_section_location_data_raw_isa,
    _dyld_section_location_objc_image_info,
    OBJC_ANDROID_SECTION_COUNT
};
struct objc_android_section { void *data; size_t size; };
struct objc_android_range { uintptr_t vmaddr; size_t vmsize; bool readOnly; };
using segmentType = objc_android_range;
struct objc_android_image {
    mach_header header;
    const char *path;
    objc_android_section sections[OBJC_ANDROID_SECTION_COUNT];
    const objc_android_range *ranges;
    size_t rangeCount;
};
using _dyld_section_location_info_t = const objc_android_image *;
struct _dyld_objc_notify_mapped_info {
    const mach_header *mh;
    const char *path;
    _dyld_section_location_info_t sectionLocationMetadata;
    uint32_t dyldObjCRefsOptimized : 1;
    uint32_t flags : 31;
};
using _dyld_objc_mark_image_mutable = void (^)(uint32_t);

template<class T>
static T *getSectionData(const headerType *, _dyld_section_location_info_t image,
                         _dyld_section_location_kind kind, size_t *count)
{
    const auto section = image ? image->sections[kind] : objc_android_section{};
    *count = section.size / sizeof(T);
    return static_cast<T *>(section.data);
}

static inline uint64_t nanoseconds() {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return uint64_t(ts.tv_sec) * 1000000000 + ts.tv_nsec;
}
const mach_header *dyld_image_header_containing_address(const void *);
static inline size_t malloc_size(const void *p) {
    // Apple's malloc_size accepts static image metadata and returns zero;
    // Bionic's malloc_usable_size requires an actual allocation and validates
    // its pointer tag. Class disposal probes both kinds of pointer.
    if (!p || dyld_image_header_containing_address(p)) { return 0; }
    return malloc_usable_size(p);
}
static inline size_t malloc_good_size(size_t size) { return size; }
static inline void *reallocf(void *ptr, size_t size) {
    void *result = realloc(ptr, size);
    if (!result && size) {
        free(ptr);
    }
    return result;
}
bool _dyld_is_memory_immutable(const void *, size_t);
static inline bool dyld_shared_cache_some_image_overridden() { return false; }
static inline bool _dyld_get_image_uuid(const mach_header *, unsigned char *) { return false; }
static inline bool dyld_program_sdk_at_least(unsigned) { return true; }
static constexpr unsigned dyld_fall_2018_os_versions = 2018;
static constexpr unsigned dyld_fall_2020_os_versions = 2020;
static constexpr unsigned dyld_platform_version_macOS_10_11 = 0;
static constexpr unsigned PLATFORM_MACOS = 1;
static inline unsigned dyld_get_active_platform() { return 0; }
const char *dyld_image_path_containing_address(const void *);
const mach_header *dyld_image_header_containing_address(const void *);
const mach_header *_dyld_get_dlopen_image_header(void *);
extern char **environ;
static inline char ***_NSGetEnviron() { return &environ; }
static inline bool issetugid() { return getuid() != geteuid() || getgid() != getegid(); }
