#include "objc-private.h"
#include "objc-loadmethod.h"
#include "objc-locks-init.h"
#include <objc/android.h>
#include <link.h>
#include <vector>
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
};
static std::atomic<RegisteredImage *> imageList;

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

static void registerImage(const objc_android_module *source) {
    for (auto p = imageList.load(); p; p = p->next) {
        if (p->source == source) { return; }
    }
    if (source->version != OBJC_ANDROID_MODULE_VERSION) {
        _objc_fatal("Unsupported Android ObjC module version %u", source->version);
    }
    Dl_info dl = {};
    if (!dladdr(source, &dl)) { _objc_fatal("Cannot locate Android ObjC module %p", source); }
    auto record = new RegisteredImage{};
    record->source = source;
    record->image.header.filetype = MH_DYLIB;
    record->image.path = strdup(dl.dli_fname);
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
        // Image removal is not implemented yet. Pin the actual mapping, rather
        // than leaving dangling class/method pointers after a caller's dlclose.
        record->pinnedHandle = dlopen(dl.dli_fname, RTLD_NOW | RTLD_NOLOAD | RTLD_NODELETE);
        if (!record->pinnedHandle) { _objc_fatal("Cannot pin ObjC image %s: %s", dl.dli_fname, dlerror()); }
    }
    record->image.ranges = static_cast<objc_android_range *>(memdup(ranges.data(), ranges.size() * sizeof(ranges[0])));
    record->image.rangeCount = ranges.size();
    record->next = imageList.load();
    imageList.store(record);

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
    if (!module) { _objc_fatal("Cannot register a null ObjC module"); }
    _objc_init();
    pthread_mutex_lock(&moduleLock);
    registerImage(objc_android_runtime_module());
    registerImage(module);
    pthread_mutex_unlock(&moduleLock);
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
        appendHeader(hi);
        mapped.push_back({hi, infos[i]});
    }
    _read_images(mapped.data(), unsigned(mapped.size()), classes, classes, makeMutable);
}

const mach_header *dyld_image_header_containing_address(const void *address) {
    uintptr_t value = uintptr_t(address);
    for (auto p = imageList.load(); p; p = p->next) {
        for (size_t i = 0; i < p->image.rangeCount; ++i) {
            auto range = p->image.ranges[i];
            if (value >= range.vmaddr && value - range.vmaddr < range.vmsize) {
                return &p->image.header;
            }
        }
    }
    return nullptr;
}
bool _dyld_is_memory_immutable(const void *address, size_t size) {
    uintptr_t value = uintptr_t(address);
    for (auto p = imageList.load(); p; p = p->next) {
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
    auto header = dyld_image_header_containing_address(address);
    return header ? reinterpret_cast<const objc_android_image *>(header)->path : nullptr;
}
const mach_header *_dyld_get_dlopen_image_header(void *) { return nullptr; }
const header_info *_headerForAddress(const void *address) {
    auto header = dyld_image_header_containing_address(address);
    for (auto hi = FirstHeader; hi; hi = hi->getNext()) {
        if (hi->mhdr() == header) { return hi; }
    }
    return nullptr;
}
const header_info *_headerForClass(Class cls) {
    return _headerForAddress(cls->safe_ro()->name.load(std::memory_order_relaxed));
}
void unmap_image_nolock(const mach_header *) {
    _objc_fatal("Unloading Objective-C images is not supported by this Android port");
}
bool hasSharedCacheDyldInfo() { return false; }
Protocol *getSharedCachePreoptimizedProtocol(const char *) { return nil; }
uintptr_t sharedCacheRelativeMethodBase() { return 0; }

// Every lookup uses the upstream slow path under runtimeLock. No assembly
// reader accesses cache buckets until an Android cache ABI is validated.
extern "C" IMP cache_getImp(Class, SEL, IMP) { return nullptr; }
