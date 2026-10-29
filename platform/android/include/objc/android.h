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

#ifdef __cplusplus
}
#endif
