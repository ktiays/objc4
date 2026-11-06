#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <objc/wasm.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static_assert(sizeof(void *) == 8, "This test requires wasm64");
static constexpr uintptr_t high = uintptr_t(1) << 32;
static bool isHigh(const void *pointer) { return uintptr_t(pointer) >= high; }
static char associationKey;

@interface Memory64Probe : NSObject
@property (nonatomic, strong) id peer;
- (void *)echo:(void *)pointer;
- (uintptr_t)address;
@end
@interface Memory64Probe (Forwarding)
- (void *)missingEcho:(void *)pointer;
@end
@implementation Memory64Probe
- (void *)echo:(void *)pointer { return pointer; }
- (uintptr_t)address { return uintptr_t(self); }
@end

@interface Memory64Error : NSObject
@end
@implementation Memory64Error
@end

static void forward(objc_wasm_invocation *invocation) {
    // A pointer result, receiver, selector and pointer argument, each i64.
    assert(strncmp(invocation->abi_signature, "p:0:ppp:", 8) == 0);
    uint64_t *arguments = static_cast<uint64_t *>(invocation->arguments);
    assert(isHigh(reinterpret_cast<void *>(uintptr_t(arguments[0]))));
    arguments[1] = uintptr_t(@selector(echo:));
    objc_wasm_invocation_invoke(invocation,
        (__bridge id)reinterpret_cast<void *>(uintptr_t(arguments[0])), nullptr);
}

int main() {
    // The test links with GLOBAL_BASE at 4 GiB: compiler-emitted metadata,
    // the stack and the heap all have nonzero upper address bits.
    int local = 0;
    assert(isHigh(&local));
    assert(isHigh((__bridge void *)[Memory64Probe class]));
    assert(isHigh(sel_getName(@selector(echo:))));
    void *allocation = malloc(16);
    assert(isHigh(allocation));
    free(allocation);
    @autoreleasepool {
        Memory64Probe *probe = [Memory64Probe new];
        assert(isHigh((__bridge void *)probe));
        assert([probe address] == uintptr_t((__bridge void *)probe));
        // Never dereferenced; checks that dispatch preserves all 64 bits.
        void *value = reinterpret_cast<void *>(high * 3 + 0x1230);
        assert([probe echo:value] == value);

        // Runtime-created metadata, method caches and a Block IMP above 4 GiB.
        Class dynamic = objc_allocateClassPair([Memory64Probe class], "Memory64Dynamic", 0);
        assert(isHigh((__bridge void *)dynamic));
        IMP block = imp_implementationWithBlock(^void *(id receiver, void *pointer) {
            assert(isHigh((__bridge void *)receiver));
            return static_cast<char *>(pointer) + 1;
        });
        assert(isHigh((__bridge void *)imp_getBlock(block)));
        assert(class_addMethod(dynamic, @selector(echo:), block, "^v@:^v"));
        objc_registerClassPair(dynamic);
        id instance = [dynamic new];
        assert(isHigh((__bridge void *)instance));
        for (int index = 0; index < 64; ++index) {
            assert([instance echo:value] == static_cast<char *>(value) + 1);
        }

        // Typed forwarding passes i64 pointer slots and an i64 pointer result.
        objc_wasm_set_forward_handler(forward);
        assert([probe missingEcho:value] == value);
        objc_wasm_set_forward_handler(nullptr);

        // ARC, weak references and associated objects.
        __weak Memory64Probe *weak;
        @autoreleasepool {
            Memory64Probe *temporary = [Memory64Probe new];
            assert(isHigh((__bridge void *)temporary));
            weak = temporary;
            probe.peer = temporary;
            objc_setAssociatedObject(probe, &associationKey, temporary,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        assert(weak != nil);
        probe.peer = nil;
        assert(weak != nil);
        objc_setAssociatedObject(probe, &associationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        assert(weak == nil);

        Memory64Error *error = [Memory64Error new];
        assert(isHigh((__bridge void *)error));
        bool caught = false;
        @try {
            @throw error;
        } @catch (Memory64Error *exception) {
            caught = exception == error;
        }
        assert(caught);

        instance = nil;
        assert(imp_removeBlock(block));
    }
    puts("PASS: wasm64 objects, metadata, caches, Block IMPs, forwarding, weak references "
         "and exceptions above 4 GiB");
}
