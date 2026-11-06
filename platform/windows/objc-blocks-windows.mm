#include "objc-private.h"
#include <Block_private.h>
#include <mutex>
#include <unordered_map>

@interface ObjC4WindowsBlock : NSObject
@end
@implementation ObjC4WindowsBlock
- (id)retain { return (id)_Block_copy(self); }
- (oneway void)release { _Block_release(self); }
- (id)autorelease { return _objc_rootAutorelease(self); }
- (id)copy { return (id)_Block_copy(self); }
- (id)copyWithZone:(struct _NSZone *)zone { return (id)_Block_copy(self); }
- (BOOL)allowsWeakReference { return !_Block_isDeallocating(self); }
- (BOOL)retainWeakReference { return _Block_tryRetain(self); }
@end
@interface ObjC4WindowsStackBlock : ObjC4WindowsBlock @end
@implementation ObjC4WindowsStackBlock @end
@interface ObjC4WindowsHeapBlock : ObjC4WindowsBlock @end
@implementation ObjC4WindowsHeapBlock @end
@interface ObjC4WindowsGlobalBlock : ObjC4WindowsBlock @end
@implementation ObjC4WindowsGlobalBlock @end

asm(".global _NSConcreteStackBlock\n"
    ".set _NSConcreteStackBlock, OBJC_CLASS_$_ObjC4WindowsStackBlock\n"
    ".global _NSConcreteMallocBlock\n"
    ".set _NSConcreteMallocBlock, OBJC_CLASS_$_ObjC4WindowsHeapBlock\n"
    ".global _NSConcreteGlobalBlock\n"
    ".set _NSConcreteGlobalBlock, OBJC_CLASS_$_ObjC4WindowsGlobalBlock\n"
    ".global _NSConcreteAutoBlock\n"
    ".set _NSConcreteAutoBlock, OBJC_CLASS_$_ObjC4WindowsHeapBlock\n"
    ".global _NSConcreteFinalizingBlock\n"
    ".set _NSConcreteFinalizingBlock, OBJC_CLASS_$_ObjC4WindowsHeapBlock\n"
    ".global _NSConcreteWeakBlockVariable\n"
    ".set _NSConcreteWeakBlockVariable, OBJC_CLASS_$_ObjC4WindowsBlock\n");

extern "C" void objc_windows_blocks_init() {
    Block_callbacks_RR callbacks = {
        sizeof(Block_callbacks_RR),
        [](const void *object) { objc_retain((id)object); },
        [](const void *object) { objc_release((id)object); },
        [](const void *object) { objc_destructInstance((id)object); }
    };
    _Block_use_RR2(&callbacks);
}

namespace {
struct Trampoline { void *page; id block; };
struct Trampolines {
    std::mutex lock;
    std::unordered_map<IMP, Trampoline> entries;
};
Trampolines &trampolines() {
    static auto *state = new Trampolines;
    return *state;
}
}

void _imp_implementationWithBlock_init() {}
IMP _imp_implementationWithBlockNoCopy(id block) {
    if (!block) { return nullptr; }
    auto *page = static_cast<unsigned char *>(VirtualAlloc(nullptr, 4096,
        MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE));
    if (!page) { _Block_release(block); return nullptr; }
#if __arm64__
    // (self, _cmd, args...) -> (block, self, args...). x8 and FP arguments
    // are untouched, including the indirect aggregate-result register.
    const uint32_t instructions[] = {0xaa0003e1, 0x58000060, 0xf9400810, 0xd61f0200};
    memcpy(page, instructions, sizeof(instructions));
    memcpy(page + 16, &block, sizeof(block));
#else
    bool stret = (reinterpret_cast<Block_layout *>(block)->flags & BLOCK_USE_STRET) != 0;
    if (stret) {
        // (result, self, _cmd, args...) -> (result, block, self, args...).
        const unsigned char instructions[] = {0x49, 0x89, 0xd0, 0x48, 0xba};
        memcpy(page, instructions, sizeof(instructions));
        memcpy(page + 5, &block, sizeof(block));
        const unsigned char jump[] = {0xff, 0x62, 0x10};
        memcpy(page + 13, jump, sizeof(jump));
    } else {
        const unsigned char instructions[] = {0x48, 0x89, 0xca, 0x48, 0xb9};
        memcpy(page, instructions, sizeof(instructions));
        memcpy(page + 5, &block, sizeof(block));
        const unsigned char jump[] = {0xff, 0x61, 0x10};
        memcpy(page + 13, jump, sizeof(jump));
    }
#endif
    DWORD previous;
    if (!VirtualProtect(page, 4096, PAGE_EXECUTE_READ, &previous) ||
        !FlushInstructionCache(GetCurrentProcess(), page, 32)) {
        VirtualFree(page, 0, MEM_RELEASE);
        _Block_release(block);
        return nullptr;
    }
    IMP implementation = reinterpret_cast<IMP>(page);
    auto &state = trampolines();
    std::lock_guard<std::mutex> lock(state.lock);
    state.entries.emplace(implementation, Trampoline{page, block});
    return implementation;
}
IMP imp_implementationWithBlock(id block) {
    return _imp_implementationWithBlockNoCopy((id)_Block_copy(block));
}
id imp_getBlock(IMP implementation) {
    auto &state = trampolines();
    std::lock_guard<std::mutex> lock(state.lock);
    auto entry = state.entries.find(implementation);
    return entry == state.entries.end() ? nil : entry->second.block;
}
BOOL imp_removeBlock(IMP implementation) {
    auto &state = trampolines();
    Trampoline trampoline;
    {
        std::lock_guard<std::mutex> lock(state.lock);
        auto entry = state.entries.find(implementation);
        if (entry == state.entries.end()) { return NO; }
        trampoline = entry->second;
        state.entries.erase(entry);
    }
    // As with Apple's API, callers must finish invoking an IMP before removing
    // it. Release captures outside the registry lock, since dealloc can reenter.
    VirtualFree(trampoline.page, 0, MEM_RELEASE);
    _Block_release(trampoline.block);
    return YES;
}
