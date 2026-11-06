#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <objc/wasm.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>

struct Pair { double x, y; };
struct Single { double value; };
struct __attribute__((packed)) Packed { char tag; uint64_t value; };

@interface WasmAdapterProbe : NSObject
- (int)value:(int)value;
- (double)floating:(float)value;
- (struct Pair)pair:(struct Pair)value;
- (struct Single)single:(struct Single)value;
- (struct Packed)packed:(struct Packed)value;
- (int)sum:(int)count, ...;
@end
@interface WasmAdapterProbe (Forwarding)
- (int)missing:(int)value;
- (struct Pair)missingPair:(struct Pair)value;
- (int)missingSum:(int)count, ...;
@end
@implementation WasmAdapterProbe
- (int)value:(int)value { return value + 1; }
- (double)floating:(float)value { return value; }
- (struct Pair)pair:(struct Pair)value { return value; }
- (struct Single)single:(struct Single)value { return value; }
- (struct Packed)packed:(struct Packed)value { return value; }
- (int)sum:(int)count, ... { return -1; }
@end

static void forward(objc_wasm_invocation *invocation) {
    unsigned receiver = (strtoul(strchr(invocation->abi_signature, ':') + 1, NULL, 10) & 1) ? 1 : 0;
    uint64_t *arguments = (uint64_t *)invocation->arguments;
    SEL selector = (SEL)(uintptr_t)arguments[receiver + 1];
    if (selector == @selector(missing:)) {
        *(int *)invocation->result = (int)arguments[receiver + 2] + 20;
    } else if (selector == @selector(missingSum:)) {
        arguments[receiver + 1] = (uintptr_t)@selector(sum:);
        objc_wasm_invocation_invoke(invocation, (__bridge id)(void *)(uintptr_t)arguments[receiver], NULL);
    } else {
        assert(selector == @selector(missingPair:));
        arguments[receiver + 1] = (uintptr_t)@selector(pair:);
        objc_wasm_invocation_invoke(invocation, (__bridge id)(void *)(uintptr_t)arguments[receiver], NULL);
    }
}

int main() {
    @autoreleasepool {
        WasmAdapterProbe *probe = [WasmAdapterProbe new];
        IMP integer = imp_implementationWithBlock(^(id receiver, int value) {
            assert(receiver == probe); return value + 10;
        });
        class_replaceMethod([WasmAdapterProbe class], @selector(value:), integer, "i@:i");
        assert([probe value:32] == 42);
        assert(imp_getBlock(integer) != nil);
        IMP floating = imp_implementationWithBlock(^(id receiver, float value) { return (double)value * 2; });
        class_replaceMethod([WasmAdapterProbe class], @selector(floating:), floating, "d@:f");
        assert([probe floating:2.5f] == 5.0);
        IMP pair = imp_implementationWithBlock(^(id receiver, struct Pair value) {
            return Pair{value.x + 1, value.y + 2};
        });
        class_replaceMethod([WasmAdapterProbe class], @selector(pair:), pair, "{Pair=dd}@:{Pair=dd}");
        Pair result = [probe pair:Pair{3, 4}];
        assert(result.x == 4 && result.y == 6);
        IMP single = imp_implementationWithBlock(^(id receiver, struct Single value) {
            return Single{value.value * 3};
        });
        class_replaceMethod([WasmAdapterProbe class], @selector(single:), single, "{Single=d}@:{Single=d}");
        assert([probe single:Single{2}].value == 6);
        IMP packed = imp_implementationWithBlock(^(id receiver, struct Packed value) {
            return Packed{value.tag, value.value + 1};
        });
        class_replaceMethod([WasmAdapterProbe class], @selector(packed:), packed, "{Packed=cQ}@:{Packed=cQ}");
        Packed packedResult = [probe packed:Packed{7, 41}];
        assert(packedResult.tag == 7 && packedResult.value == 42);
        IMP variadic = imp_implementationWithBlock(^int(id receiver, int count, ...) {
            va_list arguments; va_start(arguments, count);
            int result = 0;
            while (count--) { result += va_arg(arguments, int); }
            va_end(arguments);
            return result;
        });
        class_replaceMethod([WasmAdapterProbe class], @selector(sum:), variadic, "i@:i");
        assert(([probe sum:3, 10, 20, 12] == 42));
        objc_wasm_set_forward_handler(forward);
        assert([probe missing:22] == 42);
        IMP forwardIMP = class_getMethodImplementation([WasmAdapterProbe class], @selector(missing:));
        assert(((int (*)(id, SEL, int))forwardIMP)(probe, @selector(missing:), 22) == 42);
        assert(([probe missingSum:3, 10, 20, 12] == 42));
        result = [probe missingPair:Pair{3, 4}];
        assert(result.x == 4 && result.y == 6);
        objc_wasm_adapter_statistics before, after;
        objc_wasm_get_adapter_statistics(&before);
        assert(imp_removeBlock(integer));
        assert(!imp_removeBlock(integer));
        assert(imp_getBlock(integer) == nil);
        IMP replacement = imp_implementationWithBlock(^(id receiver, int value) { return value + 11; });
        assert(replacement == integer);
        assert([probe value:31] == 42);
        // Repeated create/remove cycles reuse the same instance and table slot.
        assert(imp_removeBlock(replacement));
        for (int index = 0; index < 2000; ++index) {
            IMP temporary = imp_implementationWithBlock(^(id receiver, int value) { return value + index; });
            assert(((int (*)(id, SEL, int))temporary)(probe, @selector(value:), 2) == 2 + index);
            assert(imp_removeBlock(temporary));
        }
        objc_wasm_get_adapter_statistics(&after);
        assert(after.instances == before.instances);
        assert(after.templates == before.templates);
        assert(imp_removeBlock(floating));
        assert(imp_removeBlock(pair));
        assert(imp_removeBlock(single));
        assert(imp_removeBlock(packed));
        assert(imp_removeBlock(variadic));
    }
    puts("PASS: dynamic Block IMPs, packed/struct/FP ABI, forwarding, swizzling and adapter recycling");
}
