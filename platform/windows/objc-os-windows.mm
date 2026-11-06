#include "objc-private.h"
#include "objc-loadmethod.h"
#include "objc-locks-init.h"
#include <bcrypt.h>
#include <mutex>
#include <vector>

namespace {
std::once_flag runtimeOnce;
struct Image {
    objc_windows_image metadata;
    objc_windows_range range;
    HMODULE module;
    Image *next;
};
std::atomic<Image *> images;
constexpr uint32_t defaultImageInfo[] = {0, 64};
extern "C" void objc_windows_blocks_init();

std::recursive_mutex &registrationLock() {
    static auto *lock = new std::recursive_mutex;
    return *lock;
}
void bootstrap() {
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
    objc_windows_blocks_init();
    didCallDyldNotifyRegister = true;
}
Image *imageForAddress(const void *address) {
    uintptr_t value = uintptr_t(address);
    for (auto *image = images.load(std::memory_order_acquire); image; image = image->next) {
        if (address == &image->metadata.header ||
            (value >= image->range.vmaddr &&
             value - image->range.vmaddr < image->range.vmsize)) { return image; }
    }
    return nullptr;
}
}

void _objc_init() { std::call_once(runtimeOnce, bootstrap); }

extern "C" void objc_windows_register_image(
    const void *address, const objc_windows_section sections[OBJC_WINDOWS_SECTION_COUNT]) {
    std::lock_guard<std::recursive_mutex> lock(registrationLock());
    _objc_init();
    if (imageForAddress(address)) { return; }
    HMODULE module;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_PIN,
                           reinterpret_cast<LPCWSTR>(address), &module)) {
        _objc_fatal("Could not pin Objective-C PE image: %lu", GetLastError());
    }
    auto *image = new Image{};
    auto *base = reinterpret_cast<const char *>(module);
    auto *dos = reinterpret_cast<const IMAGE_DOS_HEADER *>(base);
    auto *nt = reinterpret_cast<const IMAGE_NT_HEADERS *>(base + dos->e_lfanew);
    image->module = module;
    image->range = {uintptr_t(base), nt->OptionalHeader.SizeOfImage, false};
    image->metadata.header.filetype = module == GetModuleHandleW(nullptr) ? MH_EXECUTE : MH_DYLIB;
    wchar_t widePath[32768];
    DWORD length = GetModuleFileNameW(module, widePath, 32768);
    if (!length || length == 32768) { _objc_fatal("Could not read Objective-C image path"); }
    int bytes = WideCharToMultiByte(CP_UTF8, 0, widePath, -1, nullptr, 0, nullptr, nullptr);
    auto *path = static_cast<char *>(malloc(bytes));
    WideCharToMultiByte(CP_UTF8, 0, widePath, -1, path, bytes, nullptr, nullptr);
    image->metadata.path = path;
    memcpy(image->metadata.sections, sections, sizeof(image->metadata.sections));
    image->metadata.ranges = &image->range;
    image->metadata.rangeCount = 1;
    image->next = images.load(std::memory_order_relaxed);
    // Image records remain valid for process lifetime. Address queries never
    // acquire registrationLock while holding runtimeLock.
    images.store(image, std::memory_order_release);
    _dyld_objc_notify_mapped_info info = {&image->metadata.header, path, &image->metadata, 0, 0};
    map_images(1, &info, ^(uint32_t) {});
    {
        mutex_locker_t runtimeGuard(runtimeLock);
        loadAllCategoriesIfNeeded();
    }
    load_images(&info);
}

void map_images_nolock(unsigned count, const _dyld_objc_notify_mapped_info infos[],
                       bool *, _dyld_objc_mark_image_mutable makeMutable) {
    static bool first = true;
    if (first) { sel_init(0); arr_init(); first = false; }
    std::vector<mapped_image_info> mapped;
    int classes = 0;
    for (unsigned index = 0; index < count; ++index) {
        auto *header = static_cast<header_info *>(calloc(1, sizeof(header_info) + sizeof(header_info_rw)));
        header->setmhdr(infos[index].mh);
        size_t bytes = 0;
        auto *info = _getObjcImageInfo(infos[index].mh, infos[index].sectionLocationMetadata, &bytes);
        header->setinfo(info ? info : reinterpret_cast<const objc_image_info *>(defaultImageInfo));
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

extern "C" IMP objc_windows_lookup(id object, SEL selector, Class startClass) {
    return lookUpImpOrForwardTryCache(object, selector, startClass,
                                      LOOKUP_INITIALIZE | LOOKUP_RESOLVER);
}
const mach_header *dyld_image_header_containing_address(const void *address) {
    auto *image = imageForAddress(address);
    return image ? &image->metadata.header : nullptr;
}
const char *dyld_image_path_containing_address(const void *address) {
    auto *image = imageForAddress(address);
    return image ? image->metadata.path : nullptr;
}
bool _dyld_get_image_uuid(const mach_header *header, unsigned char *identifier) {
    auto *image = imageForAddress(header);
    if (!image) { return false; }
    // The upstream image-query retry loop needs a stable identity. Pinned
    // records and PE bases never get reused during this process's lifetime.
    const uintptr_t identity[] = {uintptr_t(image), uintptr_t(image->module)};
    static_assert(sizeof(identity) == sizeof(uuid_t));
    memcpy(identifier, identity, sizeof(identity));
    return true;
}
bool _dyld_is_memory_immutable(const void *address, size_t size) {
    MEMORY_BASIC_INFORMATION region;
    if (!VirtualQuery(address, &region, sizeof(region)) || region.State != MEM_COMMIT ||
        region.Type != MEM_IMAGE || (region.Protect & (PAGE_GUARD | PAGE_NOACCESS))) { return false; }
    auto protection = region.Protect & 0xff;
    return (protection == PAGE_READONLY || protection == PAGE_EXECUTE_READ) &&
        uintptr_t(address) - uintptr_t(region.BaseAddress) <= region.RegionSize &&
        size <= region.RegionSize - (uintptr_t(address) - uintptr_t(region.BaseAddress));
}
const mach_header *_dyld_get_dlopen_image_header(void *module) {
    return dyld_image_header_containing_address(module);
}
const header_info *_headerForAddress(const void *address) {
    auto *header = dyld_image_header_containing_address(address);
    for (auto *info = FirstHeader; info; info = info->getNext()) {
        if (info->mhdr() == header) { return info; }
    }
    return nullptr;
}
const header_info *_headerForClass(Class cls) {
    return _headerForAddress(cls->safe_ro()->name.load(std::memory_order_relaxed));
}
void unmap_image_nolock(const mach_header *) { _objc_fatal("Objective-C PE images remain pinned"); }
bool hasSharedCacheDyldInfo() { return false; }
Protocol *getSharedCachePreoptimizedProtocol(const char *) { return nil; }
uintptr_t sharedCacheRelativeMethodBase() { return 0; }

int getentropy(void *buffer, size_t size) {
    if (size > 256 || BCryptGenRandom(nullptr, static_cast<PUCHAR>(buffer),
            ULONG(size), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) { return -1; }
    return 0;
}
int _objc_vasprintf(char **result, const char *format, va_list arguments) {
    va_list copy;
    va_copy(copy, arguments);
    int length = vsnprintf(nullptr, 0, format, copy);
    va_end(copy);
    *result = length >= 0 ? static_cast<char *>(malloc(size_t(length) + 1)) : nullptr;
    if (!*result) { return -1; }
    return vsnprintf(*result, size_t(length) + 1, format, arguments);
}
int _objc_asprintf(char **result, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    int length = _objc_vasprintf(result, format, arguments);
    va_end(arguments);
    return length;
}
