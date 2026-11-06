#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>

static int loads;
static int initializes;
static int deallocations;
struct LargeResult { uint64_t values[5]; };

@protocol WasmProtocol
- (int)add:(int)a to:(int)b;
@end

@interface WasmProbe : NSObject <WasmProtocol>
@property(nonatomic, strong) id child;
- (int)add:(int)a to:(int)b;
- (double)mix:(double)a with:(double)b;
- (struct LargeResult)large:(uint64_t)value;
- (int)sum:(int)count, ...;
@end

@interface WasmProbe (Category)
- (int)categoryValue;
@end
@implementation WasmProbe (Category)
+ (void)load { ++loads; }
- (int)categoryValue { return 42; }
@end

@implementation WasmProbe
+ (void)load { ++loads; }
+ (void)initialize { if (self == objc_getClass("WasmProbe")) { ++initializes; } }
- (int)add:(int)a to:(int)b { return a + b; }
- (double)mix:(double)a with:(double)b { return a * 2 + b; }
- (struct LargeResult)large:(uint64_t)value {
    return (struct LargeResult){{value, value + 1, value + 2, value + 3, value + 4}};
}
- (int)sum:(int)count, ... {
    va_list arguments; va_start(arguments, count);
    int result = 0;
    while (count--) { result += va_arg(arguments, int); }
    va_end(arguments);
    return result;
}
- (void)dealloc { ++deallocations; }
@end

@interface WasmChild : WasmProbe @end
@implementation WasmChild
- (int)add:(int)a to:(int)b { return [super add:a to:b] + 10; }
@end

__attribute__((noinline))
static void *escapedDispatcher(int mode) {
    if (mode == 1) return (void *)objc_msgSend_stret;
    if (mode == 2) return (void *)objc_msgSendSuper;
    return (void *)objc_msgSend;
}

int main(void) {
    assert(loads == 2);
    __weak WasmProbe *weak;
    @autoreleasepool {
        WasmProbe *probe = [WasmProbe new];
        assert(initializes == 1);
        assert([probe conformsToProtocol:@protocol(WasmProtocol)]);
        assert([probe categoryValue] == 42);
        assert(class_getProperty([WasmProbe class], "child") != NULL);
        assert([probe add:12 to:30] == 42);
        int (*send)(id, SEL, int, int) = (void *)escapedDispatcher(0);
        assert(send(probe, @selector(add:to:), 12, 30) == 42);
        assert([probe mix:1.25 with:2.5] == 5.0);
        assert(([probe sum:4, 1, 2, 3, 4] == 10));
        struct LargeResult large = [probe large:40];
        struct LargeResult (*sendLarge)(id, SEL, uint64_t) = (void *)escapedDispatcher(1);
        large = sendLarge(probe, @selector(large:), 40);
        for (int index = 0; index < 5; ++index) {
            assert(large.values[index] == 40 + index);
        }
        WasmChild *child = [WasmChild new];
        assert([child add:12 to:30] == 52);
        struct objc_super superInfo = {child, [WasmProbe class]};
        int (*sendSuper)(struct objc_super *, SEL, int, int) = (void *)escapedDispatcher(2);
        assert(sendSuper(&superInfo, @selector(add:to:), 12, 30) == 42);
        WasmProbe *missing = nil;
        assert([missing add:1 to:2] == 0);
        assert([missing mix:1 with:2] == 0.0);
        large = [missing large:1];
        for (int index = 0; index < 5; ++index) { assert(large.values[index] == 0); }
        weak = probe;
        probe.child = [WasmProbe new];
    }
    assert(weak == nil);
    assert(deallocations >= 3);
    puts("PASS: WebAssembly registration, load/initialize, integer/FP/struct, variadic, super, nil, ARC, weak and pools");
    return 0;
}
