// AAPCS64 dispatcher for the Android port. Class discovery,
// realization, +initialize, resolution and method lookup remain in upstream objc4.
// All argument registers, including x8 (indirect result), survive the lookup.
#include "objc-cache-android.h"
.text
.p2align 2
.global objc_msgSend
.type objc_msgSend, %function
objc_msgSend:
    cbz x0, .Lnil
    ldr x16, [x0]
    b .Lcache_probe
.size objc_msgSend, .-objc_msgSend

.global objc_msgSendSuper
.type objc_msgSendSuper, %function
objc_msgSendSuper:
    ldr x16, [x0, #8]
    ldr x0, [x0]
    cbz x0, .Lnil
    b .Lcache_probe
.size objc_msgSendSuper, .-objc_msgSendSuper

.global objc_msgSendSuper2
.type objc_msgSendSuper2, %function
objc_msgSendSuper2:
    ldr x16, [x0, #8]
    ldr x16, [x16, #8]
    ldr x0, [x0]
    cbz x0, .Lnil
    b .Lcache_probe
.size objc_msgSendSuper2, .-objc_msgSendSuper2

.macro CacheReadEnd
91:
    ldxr w10, [x9]
    sub w10, w10, #1
    stlxr w11, w10, [x9]
    cbnz w11, 91b
.endm

.type objc4_android_dispatch_cache, %function
objc4_android_dispatch_cache:
.Lcache_probe:
    .cfi_startproc
#if OBJC_ANDROID_CACHE_FASTPATH
    // A reader owns only a shard count, never runtimeLock. Preserve all
    // argument registers, FP/SIMD arguments, SP, and the caller's link register.
    adrp x9, objc_android_cache_shards
    add x9, x9, :lo12:objc_android_cache_shards
    ubfx x10, x16, #4, #OBJC_ANDROID_CACHE_SHARD_BITS
    add x9, x9, x10, lsl #OBJC_ANDROID_CACHE_SHARD_SHIFT
.Lcache_read_begin:
    ldaxr w10, [x9]
    tbnz w10, #OBJC_ANDROID_CACHE_WRITER_BIT, .Lcache_writer
    add w10, w10, #1
    stxr w11, w10, [x9]
    cbnz w11, .Lcache_read_begin

    ldr w13, [x16, #OBJC_ANDROID_CACHE_MASK_OFFSET]
    cbz w13, .Lcache_miss
    ldr x12, [x16, #OBJC_ANDROID_CACHE_BUCKETS_OFFSET]
    cbz x12, .Lcache_miss
    eor x14, x1, x1, lsr #7
    and w14, w14, w13
    add w15, w13, #1
.Lcache_scan:
    add x17, x12, x14, lsl #4
    ldp x10, x11, [x17]
    cmp x11, x1
    b.eq .Lcache_hit
    cbz x11, .Lcache_miss
    subs w15, w15, #1
    b.eq .Lcache_miss
    sub w14, w14, #1
    and w14, w14, w13
    b .Lcache_scan
.Lcache_hit:
    eor x17, x10, x16  // CACHE_IMP_ENCODING_ISA_XOR
    CacheReadEnd
    br x17
.Lcache_miss:
    CacheReadEnd
    b .Llookup
.Lcache_writer:
    clrex
#endif
    b .Llookup
    .cfi_endproc
.size objc4_android_dispatch_cache, .-objc4_android_dispatch_cache

.type objc4_android_dispatch_lookup, %function
objc4_android_dispatch_lookup:
.Llookup:
    .cfi_startproc
    stp x29, x30, [sp, #-224]!
    .cfi_def_cfa_offset 224
    .cfi_offset x29, -224
    .cfi_offset x30, -216
    mov x29, sp
    .cfi_def_cfa x29, 224
    stp x0, x1, [sp, #16]
    stp x2, x3, [sp, #32]
    stp x4, x5, [sp, #48]
    stp x6, x7, [sp, #64]
    stp x8, x9, [sp, #80]
    stp q0, q1, [sp, #96]
    stp q2, q3, [sp, #128]
    stp q4, q5, [sp, #160]
    stp q6, q7, [sp, #192]
    mov x2, x16
    mov w3, #3  // LOOKUP_INITIALIZE | LOOKUP_RESOLVER
    bl lookUpImpOrForward
    mov x16, x0
    ldp q0, q1, [sp, #96]
    ldp q2, q3, [sp, #128]
    ldp q4, q5, [sp, #160]
    ldp q6, q7, [sp, #192]
    ldp x0, x1, [sp, #16]
    ldp x2, x3, [sp, #32]
    ldp x4, x5, [sp, #48]
    ldp x6, x7, [sp, #64]
    ldp x8, x9, [sp, #80]
    ldp x29, x30, [sp], #224
    .cfi_def_cfa sp, 0
    .cfi_restore x29
    .cfi_restore x30
    br x16
    .cfi_endproc
.size objc4_android_dispatch_lookup, .-objc4_android_dispatch_lookup

.global _objc_returnNil
.type _objc_returnNil, %function
_objc_returnNil:
.Lnil:
    mov x0, #0
    mov x1, #0
    mov x2, #0
    mov x3, #0
    movi v0.16b, #0
    movi v1.16b, #0
    movi v2.16b, #0
    movi v3.16b, #0
    ret
.size _objc_returnNil, .-_objc_returnNil

.global _objc_msgForward
.global _objc_msgForward_impcache
.type _objc_msgForward, %function
.type _objc_msgForward_impcache, %function
_objc_msgForward_impcache:
_objc_msgForward:
    adrp x16, :got:_objc_forward_handler
    ldr x16, [x16, :got_lo12:_objc_forward_handler]
    ldr x16, [x16]
    br x16
.size _objc_msgForward, .-_objc_msgForward

.global objc_msgSend_noarg
.set objc_msgSend_noarg, objc_msgSend
.global objc_msgSend_debug
.set objc_msgSend_debug, objc_msgSend
.global objc_msgSendSuper2_debug
.set objc_msgSendSuper2_debug, objc_msgSendSuper2
.section .note.GNU-stack,"",%progbits
