#include "objc-private.h"
#include "objc-loadmethod.h"
#include "objc-locks-init.h"
#include "objc-unload-android.h"
#include <objc/android.h>
#include <link.h>
#include <vector>
#include <unordered_map>
static_assert(OBJC_ANDROID_METADATA_SECTIONS == OBJC_ANDROID_SECTION_COUNT);

static pthread_once_t bootstrapOnce = PTHREAD_ONCE_INIT;
static pthread_mutex_t moduleLock;
extern void objc_android_blocks_init();

static void bootstrap() {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&moduleLock, &attr);
    pthread_mutexattr_destroy(&attr);

    locks_init();
    environ_init(); runtime_tls_init(); _objc_sync_init(); accessors_init();
    side_tables_init(); runtime_init(); exception_init(); cache_t::init();
    preopt_init();
    objc_android_blocks_init();
    didCallDyldNotifyRegister = true;
}

void _objc_init() { pthread_once(&bootstrapOnce, bootstrap); }



struct RegisteredImage {
    objc_android_image image;
    const objc_android_module *source;
    RegisteredImage *next;
    void *pinnedHandle;
    bool unloadable;
    bool unsupported;
    size_t liveObjects;
    objc_android_module_handle *managed;
};
struct objc_android_module_handle {
    RegisteredImage *image;
    void *nativeHandle;
    size_t leases;
    bool closing;
};
static RegisteredImage *imageList;
// Public image-name queries return borrowed strings. Keep one immutable copy
// per distinct path, independently of unloadable image-descriptor lifetimes.
static std::vector<const char *> imagePaths;
static pthread_rwlock_t imageLock = PTHREAD_RWLOCK_INITIALIZER;
static pthread_mutex_t objectLock = PTHREAD_MUTEX_INITIALIZER;
static std::unordered_map<void *, RegisteredImage *> trackedObjects;
static std::atomic<unsigned> unloadableImages;
struct ImageReadLock {
    ImageReadLock() { pthread_rwlock_rdlock(&imageLock); }
    ~ImageReadLock() { pthread_rwlock_unlock(&imageLock); }
};
struct ImageWriteLock {
    ImageWriteLock() { pthread_rwlock_wrlock(&imageLock); }
    ~ImageWriteLock() { pthread_rwlock_unlock(&imageLock); }
};
struct ModuleLock {
    ModuleLock() { pthread_mutex_lock(&moduleLock); }
    ~ModuleLock() { pthread_mutex_unlock(&moduleLock); }
};
static bool containsAddress(const void *address, const void *context) {
    auto image = static_cast<const RegisteredImage *>(context);
    uintptr_t value = uintptr_t(address);
    for (size_t i = 0; i < image->image.rangeCount; ++i) {
        auto range = image->image.ranges[i];
        if (value >= range.vmaddr && value - range.vmaddr < range.vmsize) { return true; }
    }
    return false;
}
static RegisteredImage *imageForAddress(const void *address) {
    // Caller holds imageLock or moduleLock. Only moduleLock holders mutate the
    // registry, and do so with imageLock exclusively held.
    for (auto p = imageList; p; p = p->next) {
        // header_info::fname passes the normalized runtime-owned header, not
        // an address in an ELF PT_LOAD segment.
        if (address == &p->image.header || containsAddress(address, p)) { return p; }
    }
    return nullptr;
}
static const char *internImagePath(const char *path) {
    // Registration holds moduleLock, serializing this process-lifetime pool.
    for (const char *known : imagePaths) { if (!strcmp(known, path)) { return known; } }
    const char *copy = strdup(path);
    imagePaths.push_back(copy);
    return copy;
}

struct RangeContext {
    uintptr_t base;
    std::vector<objc_android_range> *ranges;
    bool first = true;
    bool executable = false;
};
static int collectRanges(dl_phdr_info *info, size_t, void *context) {
    auto data = static_cast<RangeContext *>(context);
    bool first = data->first;
    data->first = false;
    if (info->dlpi_addr != data->base) { return 0; }
    data->executable = first;
    for (size_t i = 0; i < info->dlpi_phnum; ++i) {
        const auto &phdr = info->dlpi_phdr[i];
        if (phdr.p_type == PT_LOAD) {
            data->ranges->push_back({info->dlpi_addr + phdr.p_vaddr,
                                     size_t(phdr.p_memsz), !(phdr.p_flags & PF_W)});
        }
    }
    return 1;
}

static void registerImage(const objc_android_module *source, uint32_t flags) {
    for (auto p = imageList; p; p = p->next) {
        if (p->source == source) { return; }
    }
    if (source->version != OBJC_ANDROID_MODULE_VERSION) {
        _objc_fatal("Unsupported Android ObjC module version %u", source->version);
    }
    Dl_info dl = {};
    if (!dladdr(source, &dl)) { _objc_fatal("Cannot locate Android ObjC module %p", source); }
    auto record = new RegisteredImage{};
    record->source = source;
    record->unloadable = flags & OBJC_ANDROID_MODULE_UNLOADABLE;
    record->unsupported = flags & ~OBJC_ANDROID_MODULE_UNLOADABLE;
    record->image.header.filetype = MH_DYLIB;
    record->image.path = internImagePath(dl.dli_fname);
    for (unsigned i = 0; i < OBJC_ANDROID_SECTION_COUNT; ++i) {
        record->image.sections[i] = {source->sections[i].data, source->sections[i].size};
    }
    std::vector<objc_android_range> ranges;
    RangeContext context{uintptr_t(dl.dli_fbase), &ranges};
    dl_iterate_phdr(collectRanges, &context);
    if (ranges.empty()) { _objc_fatal("Cannot find ELF load segments for %s", dl.dli_fname); }
    if (context.executable) {
        record->image.header.filetype = MH_EXECUTE;
    } else {
        // Opt-in plugins keep a releasable native reference. Ordinary images
        // retain the original NODELETE behavior even after a raw dlclose.
        int mode = RTLD_NOW | RTLD_NOLOAD | (record->unloadable ? 0 : RTLD_NODELETE);
        record->pinnedHandle = dlopen(dl.dli_fname, mode);
        if (!record->pinnedHandle) { _objc_fatal("Cannot pin ObjC image %s: %s", dl.dli_fname, dlerror()); }
    }
    record->image.ranges = static_cast<objc_android_range *>(memdup(ranges.data(), ranges.size() * sizeof(ranges[0])));
    record->image.rangeCount = ranges.size();
    if (record->unloadable) {
        record->image.header.filetype = MH_BUNDLE;
        for (auto kind : {_dyld_section_location_data_category_list,
                         _dyld_section_location_data_category_list2,
                         _dyld_section_location_data_non_lazy_category_list,
                         _dyld_section_location_data_protocol_list,
                         _dyld_section_location_data_stub_list}) {
            record->unsupported |= record->image.sections[kind].size != 0;
        }
        auto section = record->image.sections[_dyld_section_location_objc_image_info];
        if (section.size >= sizeof(objc_image_info)) {
            record->unsupported |= static_cast<objc_image_info *>(section.data)->containsSwift();
        }
    }
    {
        ImageWriteLock lock;
        record->next = imageList;
        imageList = record;
        if (record->unloadable && !record->unsupported) { unloadableImages.fetch_add(1); }
    }

    _dyld_objc_notify_mapped_info info = {&record->image.header, record->image.path, &record->image, 0, 0};
    map_images(1, &info, ^(uint32_t) {});
    {
        mutex_locker_t lock(runtimeLock);
        loadAllCategoriesIfNeeded();
    }
    load_images(&info);
}

extern "C" const objc_android_module *objc_android_runtime_module();
extern "C" void objc_android_register_module(const objc_android_module *module) {
    objc_android_register_module_with_flags(module, 0);
}
extern "C" void objc_android_register_module_with_flags(const objc_android_module *module, uint32_t flags) {
    if (!module) { _objc_fatal("Cannot register a null ObjC module"); }
    _objc_init();
    ModuleLock lock;
    registerImage(objc_android_runtime_module(), 0);
    registerImage(module, flags);
}

void map_images_nolock(unsigned count, const _dyld_objc_notify_mapped_info infos[],
                       bool *, _dyld_objc_mark_image_mutable makeMutable) {
    static bool first = true;
    if (first) { sel_init(0); arr_init(); first = false; }
    std::vector<mapped_image_info> mapped;
    int classes = 0;
    for (unsigned i = 0; i < count; ++i) {
        auto hi = static_cast<header_info *>(calloc(1, sizeof(header_info) + sizeof(header_info_rw)));
        hi->setmhdr(infos[i].mh);
        size_t bytes = 0;
        auto imageInfo = _getObjcImageInfo(infos[i].mh, infos[i].sectionLocationMetadata, &bytes);
        static const objc_image_info emptyInfo = {0, 0};
        hi->setinfo(imageInfo ? imageInfo : &emptyInfo);
        hi->setdyldInfo(infos[i].sectionLocationMetadata); hi->setLoaded(true);
        size_t classCount = 0; hi->classlist(&classCount); classes += classCount;
        { ImageWriteLock lock; appendHeader(hi); }
        mapped.push_back({hi, infos[i]});
    }
    _read_images(mapped.data(), unsigned(mapped.size()), classes, classes, makeMutable);
}

const mach_header *dyld_image_header_containing_address(const void *address) {
    ImageReadLock lock;
    auto image = imageForAddress(address);
    return image ? &image->image.header : nullptr;
}
bool _dyld_is_memory_immutable(const void *address, size_t size) {
    uintptr_t value = uintptr_t(address);
    ImageReadLock lock;
    for (auto p = imageList; p; p = p->next) {
        // Interned selectors and copied API strings must outlive this mapping.
        if (p->unloadable) { continue; }
        for (size_t i = 0; i < p->image.rangeCount; ++i) {
            auto range = p->image.ranges[i];
            if (range.readOnly && value >= range.vmaddr &&
                value - range.vmaddr < range.vmsize &&
                size <= range.vmsize - (value - range.vmaddr)) {
                return true;
            }
        }
    }
    return false;
}
const char *dyld_image_path_containing_address(const void *address) {
    ImageReadLock lock;
    auto image = imageForAddress(address);
    return image ? image->image.path : nullptr;
}
const mach_header *_dyld_get_dlopen_image_header(void *) { return nullptr; }
const header_info *_headerForAddress(const void *address) {
    ImageReadLock lock;
    auto image = imageForAddress(address);
    auto header = image ? &image->image.header : nullptr;
    for (auto hi = FirstHeader; hi; hi = hi->getNext()) {
        if (hi->mhdr() == header) { return hi; }
    }
    return nullptr;
}
const header_info *_headerForClass(Class cls) {
    return _headerForAddress(cls->safe_ro()->name.load(std::memory_order_relaxed));
}
void unmap_image_nolock(const mach_header *header) {
    for (auto hi = FirstHeader; hi; hi = hi->getNext()) {
        if (hi->mhdr() != header) { continue; }
        _unload_image(hi);
        ImageWriteLock lock;
        removeHeader(hi);
        free(hi);
        return;
    }
}
bool hasSharedCacheDyldInfo() { return false; }
Protocol *getSharedCachePreoptimizedProtocol(const char *) { return nil; }
uintptr_t sharedCacheRelativeMethodBase() { return 0; }

void objc_android_track_object(id object, Class cls) {
    if (!object || !unloadableImages.load(std::memory_order_acquire)) { return; }
    ImageReadLock imageGuard;
    auto owner = imageForAddress(cls);
    if (owner && (!owner->unloadable || owner->unsupported)) { owner = nullptr; }
    pthread_mutex_lock(&objectLock);
    auto found = trackedObjects.find(object);
    if (found != trackedObjects.end()) {
        --found->second->liveObjects;
        trackedObjects.erase(found);
    }
    if (owner) { trackedObjects[object] = owner; ++owner->liveObjects; }
    pthread_mutex_unlock(&objectLock);
}
void objc_android_untrack_object(id object) {
    if (!unloadableImages.load(std::memory_order_acquire)) { return; }
    pthread_mutex_lock(&objectLock);
    auto found = trackedObjects.find(object);
    if (found != trackedObjects.end()) {
        --found->second->liveObjects;
        trackedObjects.erase(found);
    }
    pthread_mutex_unlock(&objectLock);
}

static bool requestedImage(const char *path, const char *actual) {
    char requested[PATH_MAX], resolved[PATH_MAX];
    if (realpath(path, requested) && realpath(actual, resolved)) { return !strcmp(requested, resolved); }
    if (strchr(path, '/')) { return !strcmp(path, actual); }
    const char *last = strrchr(actual, '/');
    return !strcmp(path, last ? last + 1 : actual);
}

objc_android_module_result objc_android_module_open(const char *path, objc_android_module_handle **out) {
    if (!out) { return OBJC_ANDROID_MODULE_INVALID; }
    *out = nullptr;
    if (!path || !*path) { return OBJC_ANDROID_MODULE_INVALID; }
    _objc_init();
    // Never hold moduleLock while entering the native loader: a constructor on
    // another thread may already hold the loader lock and need moduleLock.
    void *native = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!native) { return OBJC_ANDROID_MODULE_NATIVE_ERROR; }
    auto descriptor = reinterpret_cast<const objc_android_module *(*)()>(
        dlsym(native, "objc_android_module_descriptor_v1"));
    const auto *source = descriptor ? descriptor() : nullptr;
    auto result = OBJC_ANDROID_MODULE_NOT_UNLOADABLE;
    {
        ModuleLock lock;
        for (auto image = imageList; image; image = image->next) {
            if (image->source != source || !image->unloadable ||
                !containsAddress(reinterpret_cast<void *>(descriptor), image) ||
                !requestedImage(path, image->image.path)) { continue; }
            if (image->unsupported) { result = OBJC_ANDROID_MODULE_UNSUPPORTED; break; }
            if (image->managed) {
                result = image->managed->closing ? OBJC_ANDROID_MODULE_CLOSED : OBJC_ANDROID_MODULE_ALREADY_OPEN;
                break;
            }
            auto handle = new objc_android_module_handle{image, native, 0, false};
            image->managed = handle;
            *out = handle;
            return OBJC_ANDROID_MODULE_OK;
        }
    }
    dlclose(native);
    return result;
}
objc_android_module_result objc_android_module_acquire(objc_android_module_handle *handle) {
    if (!handle) { return OBJC_ANDROID_MODULE_INVALID; }
    ModuleLock lock;
    if (!handle->image || handle->closing) { return OBJC_ANDROID_MODULE_CLOSED; }
    ++handle->leases;
    return OBJC_ANDROID_MODULE_OK;
}
objc_android_module_result objc_android_module_release(objc_android_module_handle *handle) {
    if (!handle) { return OBJC_ANDROID_MODULE_INVALID; }
    ModuleLock lock;
    if (!handle->leases) { return OBJC_ANDROID_MODULE_INVALID; }
    --handle->leases;
    return OBJC_ANDROID_MODULE_OK;
}
objc_android_module_result objc_android_module_symbol(objc_android_module_handle *handle, const char *name, void **out) {
    if (!handle || !name || !out) { return OBJC_ANDROID_MODULE_INVALID; }
    *out = nullptr;
    void *native;
    {
        ModuleLock lock;
        if (!handle->image || handle->closing) { return OBJC_ANDROID_MODULE_CLOSED; }
        if (!handle->leases) { return OBJC_ANDROID_MODULE_INVALID; }
        ++handle->leases;
        native = handle->nativeHandle;
    }
    // A temporary lease protects dlsym without holding moduleLock across the
    // native loader. The caller's lease protects use of the returned pointer.
    *out = dlsym(native, name);
    objc_android_module_release(handle);
    return *out ? OBJC_ANDROID_MODULE_OK : OBJC_ANDROID_MODULE_NATIVE_ERROR;
}
objc_android_module_result objc_android_module_close(objc_android_module_handle *handle) {
    if (!handle) { return OBJC_ANDROID_MODULE_INVALID; }
    RegisteredImage *image;
    void *native, *pin;
    {
        ModuleLock lock;
        image = handle->image;
        if (!image || handle->closing) { return OBJC_ANDROID_MODULE_CLOSED; }
        if (image->unsupported) { return OBJC_ANDROID_MODULE_UNSUPPORTED; }
        if (handle->leases) { return OBJC_ANDROID_MODULE_BUSY_LEASES; }
        pthread_mutex_lock(&objectLock);
        bool live = image->liveObjects != 0;
        pthread_mutex_unlock(&objectLock);
        if (live) { return OBJC_ANDROID_MODULE_BUSY_OBJECTS; }
        handle->closing = true;
    }
    // Do not hold moduleLock while waiting for any ObjC runtime locks. A
    // callback under such a lock can attempt acquire and promptly see CLOSED.
    // The closing state keeps this image/handle alive and blocks new leases.
    bool dependency = false;
    for (auto kind : {_dyld_section_location_data_class_list,
                     _dyld_section_location_data_non_lazy_class_list}) {
        auto section = image->image.sections[kind];
        auto classes = static_cast<Class *>(section.data);
        for (size_t i = 0; i < section.size / sizeof(Class); ++i) {
            // Owners clear associations explicitly; no user destructors run
            // during close's preflight or metadata removal.
            dependency |= objc_android_class_has_associations(classes[i]) ||
                          objc_android_class_has_associations(classes[i]->ISA());
        }
    }
    if (!dependency) {
        recursive_mutex_locker_t loadGuard(loadMethodLock);
        mutex_locker_t runtimeGuard(runtimeLock);
        header_info *header = FirstHeader;
        while (header && header->mhdr() != &image->image.header) { header = header->getNext(); }
        dependency = !header || objc_android_image_has_dependencies(header, containsAddress, image);
        if (!dependency) {
            objc_android_flush_caches_nolock();
            unmap_image_nolock(&image->image.header);
        }
    }
    {
        ModuleLock lock;
        if (dependency) {
            handle->closing = false;
            return OBJC_ANDROID_MODULE_DEPENDENCY;
        }
        {
            ImageWriteLock imageGuard;
            RegisteredImage **link = &imageList;
            while (*link != image) { link = &(*link)->next; }
            *link = image->next;
            unloadableImages.fetch_sub(1);
        }
        native = handle->nativeHandle; pin = image->pinnedHandle;
        handle->image = nullptr; handle->nativeHandle = nullptr;
    }
    // No runtime/registry locks across ELF finalizers. A closed handle remains
    // usable for CLOSED results until the owner explicitly destroys it.
    int first = dlclose(native), second = dlclose(pin);
    free(const_cast<objc_android_range *>(image->image.ranges));
    delete image;
    return first || second ? OBJC_ANDROID_MODULE_NATIVE_ERROR : OBJC_ANDROID_MODULE_OK;
}
objc_android_module_result objc_android_module_destroy(objc_android_module_handle *handle) {
    if (!handle) { return OBJC_ANDROID_MODULE_INVALID; }
    ModuleLock lock;
    if (handle->image || handle->leases) { return OBJC_ANDROID_MODULE_BUSY_LEASES; }
    delete handle;
    return OBJC_ANDROID_MODULE_OK;
}
const char *objc_android_module_result_string(objc_android_module_result result) {
    switch (result) {
        case OBJC_ANDROID_MODULE_OK: return "ok";
        case OBJC_ANDROID_MODULE_INVALID: return "invalid argument or unbalanced release";
        case OBJC_ANDROID_MODULE_NATIVE_ERROR: return "native loader error";
        case OBJC_ANDROID_MODULE_NOT_UNLOADABLE: return "image did not opt into controlled unloading";
        case OBJC_ANDROID_MODULE_ALREADY_OPEN: return "image already has a managed handle";
        case OBJC_ANDROID_MODULE_CLOSED: return "module is closing or closed";
        case OBJC_ANDROID_MODULE_BUSY_LEASES: return "active leases or an open handle";
        case OBJC_ANDROID_MODULE_BUSY_OBJECTS: return "live Objective-C instances";
        case OBJC_ANDROID_MODULE_DEPENDENCY: return "external runtime dependency";
        case OBJC_ANDROID_MODULE_UNSUPPORTED: return "unsupported unloadable metadata";
    }
    return "unknown result";
}

#if OBJC_ANDROID_TESTING
extern "C" __attribute__((visibility("default")))
void objc4_android_test_with_runtime_lock(void (*body)(void *), void *context) {
    mutex_locker_t lock(runtimeLock);
    body(context);
}
#endif
