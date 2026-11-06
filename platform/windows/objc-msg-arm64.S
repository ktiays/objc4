.text
.p2align 2
.globl objc_msgSend
objc_msgSend:
    cbz x0, _objc_returnNil
    ldr x16, [x0]
    b objc4_windows_dispatch

.globl objc_msgSendSuper
objc_msgSendSuper:
    ldr x16, [x0, #8]
    ldr x0, [x0]
    cbz x0, _objc_returnNil
    b objc4_windows_dispatch

.globl objc_msgSendSuper2
objc_msgSendSuper2:
    ldr x16, [x0, #8]
    ldr x16, [x16, #8]
    ldr x0, [x0]
    cbz x0, _objc_returnNil
    b objc4_windows_dispatch

// Preserve all argument registers, x8's indirect result, and stack arguments.
// SEH describes the non-leaf lookup frame for C++/Objective-C exceptions.
.seh_proc objc4_windows_dispatch
objc4_windows_dispatch:
    stp x29, x30, [sp, #-224]!
    .seh_save_fplr_x 224
    mov x29, sp
    .seh_set_fp
    .seh_endprologue
    stp x0, x1, [sp, #16]
    stp x2, x3, [sp, #32]
    stp x4, x5, [sp, #48]
    stp x6, x7, [sp, #64]
    str x8, [sp, #80]
    stp q0, q1, [sp, #96]
    stp q2, q3, [sp, #128]
    stp q4, q5, [sp, #160]
    stp q6, q7, [sp, #192]
    mov x2, x16
    bl objc_windows_lookup
    mov x16, x0
    ldp q0, q1, [sp, #96]
    ldp q2, q3, [sp, #128]
    ldp q4, q5, [sp, #160]
    ldp q6, q7, [sp, #192]
    ldp x0, x1, [sp, #16]
    ldp x2, x3, [sp, #32]
    ldp x4, x5, [sp, #48]
    ldp x6, x7, [sp, #64]
    ldr x8, [sp, #80]
    .seh_startepilogue
    ldp x29, x30, [sp], #224
    .seh_save_fplr_x 224
    .seh_endepilogue
    br x16
    .seh_endproc

.globl _objc_returnNil
_objc_returnNil:
    mov x0, #0
    mov x1, #0
    mov x2, #0
    mov x3, #0
    movi v0.16b, #0
    movi v1.16b, #0
    movi v2.16b, #0
    movi v3.16b, #0
    ret

.globl _objc_msgForward
.globl _objc_msgForward_impcache
_objc_msgForward:
_objc_msgForward_impcache:
    adrp x16, _objc_forward_handler
    ldr x16, [x16, :lo12:_objc_forward_handler]
    br x16

.globl objc_msgSend_noarg
.set objc_msgSend_noarg, objc_msgSend
.globl objc_msgSend_debug
.set objc_msgSend_debug, objc_msgSend
.globl objc_msgSendSuper2_debug
.set objc_msgSendSuper2_debug, objc_msgSendSuper2
