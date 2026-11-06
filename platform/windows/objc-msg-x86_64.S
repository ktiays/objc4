.text
.p2align 4
.globl objc_msgSend
objc_msgSend:
    testq %rcx, %rcx
    jz _objc_returnNil
    movq (%rcx), %r10
    jmp objc4_windows_dispatch

.globl objc_msgSendSuper
objc_msgSendSuper:
    movq 8(%rcx), %r10
    movq (%rcx), %rcx
    testq %rcx, %rcx
    jz _objc_returnNil
    jmp objc4_windows_dispatch

.globl objc_msgSendSuper2
objc_msgSendSuper2:
    movq 8(%rcx), %r10
    movq 8(%r10), %r10
    movq (%rcx), %rcx
    testq %rcx, %rcx
    jz _objc_returnNil
    jmp objc4_windows_dispatch

.globl objc_msgSend_stret
objc_msgSend_stret:
    testq %rdx, %rdx
    jz _objc_returnNil
    movq (%rdx), %r10
    jmp objc4_windows_dispatch_stret

.globl objc_msgSendSuper_stret
objc_msgSendSuper_stret:
    movq 8(%rdx), %r10
    movq (%rdx), %rdx
    jmp objc4_windows_dispatch_stret

.globl objc_msgSendSuper2_stret
objc_msgSendSuper2_stret:
    movq 8(%rdx), %r10
    movq 8(%r10), %r10
    movq (%rdx), %rdx
    jmp objc4_windows_dispatch_stret

.macro Lookup name, stret=0
.seh_proc \name
\name:
    subq $136, %rsp
    .seh_stackalloc 136
    .seh_endprologue
    movq %rcx, 32(%rsp)
    movq %rdx, 40(%rsp)
    movq %r8, 48(%rsp)
    movq %r9, 56(%rsp)
    movaps %xmm0, 64(%rsp)
    movaps %xmm1, 80(%rsp)
    movaps %xmm2, 96(%rsp)
    movaps %xmm3, 112(%rsp)
.if \stret
    movq %rdx, %rcx
    movq %r8, %rdx
.endif
    movq %r10, %r8
    callq objc_windows_lookup
    movq %rax, %r11
.if \stret
    leaq _objc_msgForward_impcache(%rip), %rax
    cmpq %rax, %r11
    jne 1f
    leaq _objc_msgForward_stret(%rip), %r11
1:
.endif
    movq 32(%rsp), %rcx
    movq 40(%rsp), %rdx
    movq 48(%rsp), %r8
    movq 56(%rsp), %r9
    movaps 64(%rsp), %xmm0
    movaps 80(%rsp), %xmm1
    movaps 96(%rsp), %xmm2
    movaps 112(%rsp), %xmm3
    addq $136, %rsp
    jmpq *%r11
.seh_endproc
.endm
Lookup objc4_windows_dispatch
Lookup objc4_windows_dispatch_stret, 1

.globl _objc_returnNil
_objc_returnNil:
    xorl %eax, %eax
    xorl %edx, %edx
    xorps %xmm0, %xmm0
    xorps %xmm1, %xmm1
    retq

.globl _objc_msgForward
.globl _objc_msgForward_impcache
_objc_msgForward:
_objc_msgForward_impcache:
    jmpq *_objc_forward_handler(%rip)
.globl _objc_msgForward_stret
_objc_msgForward_stret:
    jmpq *_objc_forward_stret_handler(%rip)

.globl objc_msgSend_noarg
.set objc_msgSend_noarg, objc_msgSend
.globl objc_msgSend_debug
.set objc_msgSend_debug, objc_msgSend
.globl objc_msgSendSuper2_debug
.set objc_msgSendSuper2_debug, objc_msgSendSuper2
.globl objc_msgSend_fpret
// LLVM-MinGW returns long double and complex long double indirectly.
.set objc_msgSend_fpret, objc_msgSend_stret
.globl objc_msgSend_fp2ret
.set objc_msgSend_fp2ret, objc_msgSend_stret
.globl _objc_msgNil
.set _objc_msgNil, _objc_returnNil
.globl _objc_msgNil_stret
.set _objc_msgNil_stret, _objc_returnNil
.globl _objc_msgNil_fpret
_objc_msgNil_fpret:
    jmp _objc_returnNil
.globl _objc_msgNil_fp2ret
.set _objc_msgNil_fp2ret, _objc_returnNil
