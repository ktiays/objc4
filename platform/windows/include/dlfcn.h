#pragma once
#include <windows.h>

typedef struct {
    const char *dli_fname;
    void *dli_fbase;
    const char *dli_sname;
    void *dli_saddr;
} Dl_info;

static inline int dladdr(const void *address, Dl_info *info) {
    HMODULE module;
    if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)address, &module)) { return 0; }
#ifdef __cplusplus
    static thread_local char path[32768];
#else
    static __thread char path[32768];
#endif
    if (!GetModuleFileNameA(module, path, sizeof(path))) { return 0; }
    info->dli_fname = path;
    info->dli_fbase = module;
    info->dli_sname = 0;
    info->dli_saddr = 0;
    return 1;
}
