#pragma once

#include <objc/objc.h>
#include <stddef.h>
#include <stdint.h>

__BEGIN_DECLS

// Initializes the statically linked Objective-C image and executes +load.
// Startup calls this automatically; repeated calls are harmless.
OBJC_EXPORT void objc_wasm_init(void);

// Slots contain the lowered C ABI values, including self, _cmd and any sret
// or varargs-buffer pointer. Each slot occupies eight bytes. The signature is
// "return:flags:parameters:resultSize": v=void, p=pointer, i=i32, j=i64,
// f=f32, d=f64. resultSize is the sret buffer size or the direct result slot size.
// Flag 1 denotes sret; flag 2 denotes a trailing varargs-buffer pointer.
typedef struct objc_wasm_invocation {
    const char *abi_signature;
    void *arguments;
    void *result;
    void (*invoke)(void *arguments, void *result, IMP implementation);
} objc_wasm_invocation;

typedef void (*objc_wasm_forward_handler)(objc_wasm_invocation *invocation);
OBJC_EXPORT objc_wasm_forward_handler
objc_wasm_set_forward_handler(objc_wasm_forward_handler handler);

// Invoke with the original ABI after changing the receiver slot, or supply a
// compatible IMP. Passing NULL as the IMP performs ordinary method lookup.
OBJC_EXPORT void objc_wasm_invocation_invoke(objc_wasm_invocation *invocation,
                                            id receiver, IMP implementation);

typedef struct objc_wasm_adapter_statistics {
    size_t templates;
    size_t instances;
    size_t active_block_imps;
} objc_wasm_adapter_statistics;
OBJC_EXPORT void objc_wasm_get_adapter_statistics(objc_wasm_adapter_statistics *out);

__END_DECLS
