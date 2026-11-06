#include "objc-private.h"
#include "objc-loadmethod.h"
#include "objc-locks-init.h"
#include <objc/wasm.h>
#include <vector>

namespace {
pthread_once_t runtimeOnce = PTHREAD_ONCE_INIT;
pthread_mutex_t registrationLock;
bool registered;
objc_wasm_image image;
objc_wasm_range imageRange;

extern "C" void objc_wasm_blocks_init();

void bootstrap() {
    pthread_mutexattr_t attributes;
    pthread_mutexattr_init(&attributes);
    pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&registrationLock, &attributes);
    pthread_mutexattr_destroy(&attributes);
    locks_init();
    environ_init();
    runtime_tls_init();
    _objc_sync_init();
    accessors_init();
    side_tables_init();
    runtime_init();
    exception_init();
    cache_t::init();
    preopt_init();
    objc_wasm_blocks_init();
    didCallDyldNotifyRegister = true;
}

#define SECTION(name) \
    extern "C" char __start_##name[] __attribute__((weak, visibility("hidden"))); \
    extern "C" char __stop_##name[] __attribute__((weak, visibility("hidden")));
SECTION(objc_selrefs)
SECTION(objc_msgrefs)
SECTION(objc_classrefs)
SECTION(objc_superrefs)
SECTION(objc_protorefs)
SECTION(objc_classlist)
SECTION(objc_nlclslist)
SECTION(objc_stublist)
SECTION(objc_catlist)
SECTION(objc_catlist2)
SECTION(objc_nlcatlist)
SECTION(objc_protolist)
SECTION(objc_fork_ok)
SECTION(objc_rawisa)
SECTION(objc_imageinfo)
#undef SECTION

extern "C" char __global_base;
extern "C" char __data_end;

__attribute__((used, section("objc_imageinfo")))
const uint32_t imageInfo[] = {0, 64};

bool isStaticAddress(const void *address) {
    auto value = uintptr_t(address);
    return value >= uintptr_t(&__global_base) && value < uintptr_t(&__data_end);
}
}

void _objc_init() { pthread_once(&runtimeOnce, bootstrap); }

extern "C" void objc_wasm_init() {
    _objc_init();
    pthread_mutex_lock(&registrationLock);
    struct Unlock {
        ~Unlock() { pthread_mutex_unlock(&registrationLock); }
    } unlock;
    if (!registered) {
        // +load can reenter initialization through ordinary message sends.
        registered = true;
        image.header.filetype = MH_EXECUTE;
        image.path = "<wasm>";
        imageRange = {uintptr_t(&__global_base),
                      uintptr_t(&__data_end) - uintptr_t(&__global_base), false};
        image.ranges = &imageRange;
        image.rangeCount = 1;
#define SET(index, name) \
        image.sections[index] = {__start_##name, \
            uintptr_t(__stop_##name) - uintptr_t(__start_##name)};
        SET(0, objc_selrefs)
        SET(1, objc_msgrefs)
        SET(2, objc_classrefs)
        SET(3, objc_superrefs)
        SET(4, objc_protorefs)
        SET(5, objc_classlist)
        SET(6, objc_nlclslist)
        SET(7, objc_stublist)
        SET(8, objc_catlist)
        SET(9, objc_catlist2)
        SET(10, objc_nlcatlist)
        SET(11, objc_protolist)
        SET(12, objc_fork_ok)
        SET(13, objc_rawisa)
        SET(14, objc_imageinfo)
#undef SET
        _dyld_objc_notify_mapped_info info = {&image.header, image.path, &image, 0, 0};
        map_images(1, &info, ^(uint32_t) {});
        {
            mutex_locker_t lock(runtimeLock);
            loadAllCategoriesIfNeeded();
        }
        load_images(&info);
    }
}

__attribute__((constructor))
static void initializeImage() { objc_wasm_init(); }

void map_images_nolock(unsigned count, const _dyld_objc_notify_mapped_info infos[],
                       bool *, _dyld_objc_mark_image_mutable makeMutable) {
    static bool first = true;
    if (first) { sel_init(0); arr_init(); first = false; }
    std::vector<mapped_image_info> mapped;
    int classes = 0;
    for (unsigned index = 0; index < count; ++index) {
        auto header = static_cast<header_info *>(calloc(1, sizeof(header_info) + sizeof(header_info_rw)));
        header->setmhdr(infos[index].mh);
        size_t bytes = 0;
        auto info = _getObjcImageInfo(infos[index].mh, infos[index].sectionLocationMetadata, &bytes);
        header->setinfo(info ? info : reinterpret_cast<const objc_image_info *>(imageInfo));
        header->setdyldInfo(infos[index].sectionLocationMetadata);
        header->setLoaded(true);
        size_t classCount = 0;
        header->classlist(&classCount);
        classes += classCount;
        appendHeader(header);
        mapped.push_back({header, infos[index]});
    }
    _read_images(mapped.data(), unsigned(mapped.size()), classes, classes, makeMutable);
}

extern "C" IMP objc_wasm_forward_imp(const char *signature);
extern "C" IMP objc_wasm_lookup(id object, SEL selector, Class startClass,
                                const char *signature) {
    if (!object) { return nullptr; }
    objc_wasm_init();
    Class cls = startClass ? startClass : object->getIsa();
    IMP implementation = lookUpImpOrForwardTryCache(object, selector, cls,
                                      LOOKUP_INITIALIZE | LOOKUP_RESOLVER);
    if (implementation == (IMP)_objc_msgForward_impcache ||
        implementation == (IMP)_objc_msgForward) {
        return objc_wasm_forward_imp(signature);
    }
    return implementation;
}

const mach_header *dyld_image_header_containing_address(const void *address) {
    return isStaticAddress(address) ? &image.header : nullptr;
}
bool _dyld_is_memory_immutable(const void *, size_t) { return false; }
const char *dyld_image_path_containing_address(const void *address) {
    return isStaticAddress(address) ? image.path : nullptr;
}
const mach_header *_dyld_get_dlopen_image_header(void *) { return nullptr; }
const header_info *_headerForAddress(const void *address) {
    return isStaticAddress(address) ? FirstHeader : nullptr;
}
const header_info *_headerForClass(Class cls) {
    return _headerForAddress(cls->safe_ro()->name.load(std::memory_order_relaxed));
}
void unmap_image_nolock(const mach_header *) {
    _objc_fatal("The statically linked WebAssembly image cannot be unloaded");
}
bool hasSharedCacheDyldInfo() { return false; }
Protocol *getSharedCachePreoptimizedProtocol(const char *) { return nil; }
uintptr_t sharedCacheRelativeMethodBase() { return 0; }
