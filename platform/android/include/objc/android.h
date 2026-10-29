#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { OBJC_ANDROID_MODULE_VERSION = 1, OBJC_ANDROID_METADATA_SECTIONS = 15 };
struct objc_android_metadata_section { void *data; size_t size; };
struct objc_android_module {
    uint32_t version;
    struct objc_android_metadata_section sections[OBJC_ANDROID_METADATA_SECTIONS];
};

// Register one ELF image before executing its Objective-C code. Use the CMake
// objc4_add_android_module helper to retain metadata and install this hook.
__attribute__((visibility("default")))
void objc_android_register_module(const struct objc_android_module *module);

enum { OBJC_ANDROID_MODULE_UNLOADABLE = 1 };
__attribute__((visibility("default")))
void objc_android_register_module_with_flags(const struct objc_android_module *, uint32_t flags);

typedef struct objc_android_module_handle objc_android_module_handle;
typedef enum objc_android_module_result {
    OBJC_ANDROID_MODULE_OK = 0,
    OBJC_ANDROID_MODULE_INVALID,
    OBJC_ANDROID_MODULE_NATIVE_ERROR,
    OBJC_ANDROID_MODULE_NOT_UNLOADABLE,
    OBJC_ANDROID_MODULE_ALREADY_OPEN,
    OBJC_ANDROID_MODULE_CLOSED,
    OBJC_ANDROID_MODULE_BUSY_LEASES,
    OBJC_ANDROID_MODULE_BUSY_OBJECTS,
    OBJC_ANDROID_MODULE_DEPENDENCY,
    OBJC_ANDROID_MODULE_UNSUPPORTED
} objc_android_module_result;

// Controlled class-plugin unloading. Every use of plugin code/metadata,
// including direct IMP calls, callbacks, Blocks and ARC cleanup, must be covered
// by a lease. Escaped callbacks/Blocks/borrowed metadata must retain a lease.
// Ordinary runtime-created objects are also tracked while idle, but accessing
// or releasing them still requires a lease. Stop producers and drain pools
// before close. Busy/dependency failures leave the module open. Once metadata
// removal commits, the handle stays closed even if native dlclose reports error.
// A successful close invalidates its Class/Method/IMP/object pointers; the
// handle stays valid until destroy.
// destroy requires a closed handle and caller synchronization against all other
// handle operations. ELF finalizers must not use Objective-C after close.
__attribute__((visibility("default")))
objc_android_module_result objc_android_module_open(const char *path, objc_android_module_handle **out);
__attribute__((visibility("default")))
objc_android_module_result objc_android_module_acquire(objc_android_module_handle *);
__attribute__((visibility("default")))
objc_android_module_result objc_android_module_release(objc_android_module_handle *);
// Look up a native export while a caller-owned lease is active. The returned
// pointer is borrowed and must not outlive that lease.
__attribute__((visibility("default")))
objc_android_module_result objc_android_module_symbol(objc_android_module_handle *, const char *, void **out);
__attribute__((visibility("default")))
objc_android_module_result objc_android_module_close(objc_android_module_handle *);
__attribute__((visibility("default")))
objc_android_module_result objc_android_module_destroy(objc_android_module_handle *);
__attribute__((visibility("default")))
const char *objc_android_module_result_string(objc_android_module_result);

#ifdef __cplusplus
}
#endif
