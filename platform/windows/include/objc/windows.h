#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Each PE image supplies its metadata section bounds through the module helper
// added by objc4_add_windows_module(). The runtime pins registered DLLs.
struct objc_windows_section { void *data; size_t size; };
void objc_windows_register_image(const void *address,
                                const struct objc_windows_section sections[15]);

#ifdef __cplusplus
}
#endif
