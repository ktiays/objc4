#pragma once

#include <malloc.h>
#include <time.h>
#include <windows.h>
#include <objc/windows.h>
#include <mach-o/loader.h>
#include "Threading/threading.h"

using spinlock_t = objc_lock_t;
using mutex_t = objc_lock_t;
using recursive_mutex_t = objc_recursive_lock_t;
using mutex_locker_t = mutex_t::locker;
using conditional_mutex_locker_t = mutex_t::conditional_locker;
using headerType = mach_header;
using uuid_t = unsigned char[16];

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
    OBJC_WINDOWS_SECTION_COUNT
};


struct objc_windows_range { uintptr_t vmaddr; size_t vmsize; bool readOnly; };
using segmentType = objc_windows_range;
struct objc_windows_image {
    mach_header header;
    const char *path;
    objc_windows_section sections[OBJC_WINDOWS_SECTION_COUNT];
    const objc_windows_range *ranges;
    size_t rangeCount;
};
using _dyld_section_location_info_t = const objc_windows_image *;
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
                         _dyld_section_location_kind kind, size_t *count) {
    auto section = image ? image->sections[kind] : objc_windows_section{};
    *count = section.size / sizeof(T);
    return static_cast<T *>(section.data);
}

static inline uint64_t nanoseconds() {
    LARGE_INTEGER counter, frequency;
    QueryPerformanceCounter(&counter);
    QueryPerformanceFrequency(&frequency);
    return uint64_t(counter.QuadPart / frequency.QuadPart) * 1000000000 +
        uint64_t(counter.QuadPart % frequency.QuadPart) * 1000000000 / frequency.QuadPart;
}
const mach_header *dyld_image_header_containing_address(const void *);
static inline size_t malloc_size(const void *pointer) {
    if (!pointer || dyld_image_header_containing_address(pointer)) { return 0; }
    return _msize(const_cast<void *>(pointer));
}
static inline size_t malloc_good_size(size_t size) { return size; }
static inline void *reallocf(void *pointer, size_t size) {
    void *result = realloc(pointer, size);
    if (!result && size) { free(pointer); }
    return result;
}
bool _dyld_is_memory_immutable(const void *, size_t);
static inline bool dyld_shared_cache_some_image_overridden() { return false; }
bool _dyld_get_image_uuid(const mach_header *, unsigned char *);
static inline bool dyld_program_sdk_at_least(unsigned) { return true; }
static constexpr unsigned dyld_fall_2018_os_versions = 2018;
static constexpr unsigned dyld_fall_2020_os_versions = 2020;
static constexpr unsigned dyld_platform_version_macOS_10_11 = 0;
static constexpr unsigned PLATFORM_MACOS = 1;
static inline unsigned dyld_get_active_platform() { return 0; }
const char *dyld_image_path_containing_address(const void *);
const mach_header *_dyld_get_dlopen_image_header(void *);
static inline char ***_NSGetEnviron() { return __p__environ(); }

static inline bool issetugid() { return false; }
int getentropy(void *, size_t);
