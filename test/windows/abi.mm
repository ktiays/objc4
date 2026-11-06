#include <objc/NSObject.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <assert.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>

struct LargeResult { uint64_t values[5]; };
struct FloatingResult { double values[4]; };
static int resolved(id, SEL) { return 64; }
static int forwarded(id, SEL, int value) { return value + 40; }
static LargeResult forwardedLarge(id, SEL, uint64_t value) {
    return {{value, value + 1, value + 2, value + 3, value + 4}};
}

@interface WindowsABI : NSObject
- (uint64_t)integers:(uint64_t)a :(uint64_t)b :(uint64_t)c :(uint64_t)d
    :(uint64_t)e :(uint64_t)f :(uint64_t)g :(uint64_t)h :(uint64_t)i :(uint64_t)j;
- (double)floating:(double)a :(double)b :(double)c :(double)d :(double)e
    :(double)f :(double)g :(double)h :(double)i :(double)j;
- (double)variadic:(int)count, ...;
- (long double)extended:(long double)value;
- (struct LargeResult)large:(uint64_t)value;
- (struct FloatingResult)aggregate:(struct FloatingResult)value;
- (int)resolvedValue;
- (int)missing:(int)value;
- (struct LargeResult)missingLarge:(uint64_t)value;
@end
@implementation WindowsABI
+ (BOOL)resolveInstanceMethod:(SEL)selector {
    if (selector == @selector(resolvedValue)) {
        return class_addMethod(self, selector, (IMP)resolved, "i@:");
    }
    return [super resolveInstanceMethod:selector];
}
- (uint64_t)integers:(uint64_t)a :(uint64_t)b :(uint64_t)c :(uint64_t)d
    :(uint64_t)e :(uint64_t)f :(uint64_t)g :(uint64_t)h :(uint64_t)i :(uint64_t)j {
    return a + b + c + d + e + f + g + h + i + j;
}
- (double)floating:(double)a :(double)b :(double)c :(double)d :(double)e
    :(double)f :(double)g :(double)h :(double)i :(double)j {
    return a + b + c + d + e + f + g + h + i + j;
}
- (double)variadic:(int)count, ... {
    va_list arguments;
    va_start(arguments, count);
    double result = 0;
    while (count--) { result += va_arg(arguments, double); }
    va_end(arguments);
    return result;
}
- (struct LargeResult)large:(uint64_t)value {
    return {{value, value + 1, value + 2, value + 3, value + 4}};
}
- (long double)extended:(long double)value { return value * 2; }
- (struct FloatingResult)aggregate:(struct FloatingResult)value { return value; }
@end
@interface WindowsABISubclass : WindowsABI @end
@implementation WindowsABISubclass
- (struct LargeResult)large:(uint64_t)value { return [super large:value + 1]; }
@end

int main() {
    @autoreleasepool {
        WindowsABI *object = [WindowsABISubclass new];
        for (int pass = 0; pass < 10; ++pass) {
            assert([object integers:1 :2 :3 :4 :5 :6 :7 :8 :9 :10] == 55);
            assert([object floating:1 :2 :3 :4 :5 :6 :7 :8 :9 :10] == 55);
            assert(([object variadic:6, 0.5, 1.5, 2.5, 3.5, 4.5, 5.5] == 18));
            assert([object large:40].values[0] == 41);
            assert([object extended:1.25L] == 2.5L);
#if defined(__x86_64__)
            assert(((long double (*)(id, SEL, long double))objc_msgSend_fpret)(
                object, @selector(extended:), 1.25L) == 2.5L);
#endif
            FloatingResult argument = {{1.25, 2.5, 3.75, 5}};
            FloatingResult result = [object aggregate:argument];
            for (int index = 0; index < 4; ++index) { assert(result.values[index] == argument.values[index]); }
        }
        assert([object resolvedValue] == 64);
        objc_setForwardHandler((void *)forwarded, (void *)forwarded);
        assert([object missing:2] == 42);
#if defined(__x86_64__)
        objc_setForwardHandler((void *)forwarded, (void *)forwardedLarge);
#else
        objc_setForwardHandler((void *)forwardedLarge, (void *)forwardedLarge);
#endif
        assert([object missingLarge:42].values[4] == 46);

        __weak id weak;
        IMP implementation;
        @autoreleasepool {
            id capture = [NSObject new];
            weak = capture;
            implementation = imp_implementationWithBlock(^(id receiver, int value) {
                assert(receiver == object && capture != nil);
                return value + 40;
            });
            assert(implementation && imp_getBlock(implementation));
            assert(((int (*)(id, SEL, int))implementation)(object, @selector(missing:), 2) == 42);
            assert(imp_removeBlock(implementation));
            assert(!imp_getBlock(implementation) && !imp_removeBlock(implementation));
        }
        assert(weak == nil);

        implementation = imp_implementationWithBlock(^(id receiver, double value) { return value * 2; });
        assert(((double (*)(id, SEL, double))implementation)(object, @selector(missing:), 2.5) == 5);
        assert(imp_removeBlock(implementation));
        implementation = imp_implementationWithBlock(^LargeResult(id receiver, uint64_t value) {
            return LargeResult{{value, value + 1, value + 2, value + 3, value + 4}};
        });
        LargeResult result = ((LargeResult (*)(id, SEL, uint64_t))implementation)(object, @selector(large:), 42);
        assert(result.values[0] == 42 && result.values[4] == 46);
        assert(imp_removeBlock(implementation));

        Class dynamic = objc_allocateClassPair([NSObject class], "WindowsCacheGrowth", 0);
        assert(dynamic);
        SEL selectors[192];
        for (int index = 0; index < 192; ++index) {
            char name[64];
            snprintf(name, sizeof(name), "cacheGrowthMethod_%d", index);
            selectors[index] = sel_registerName(name);
            assert(class_addMethod(dynamic, selectors[index], (IMP)resolved, "i@:"));
        }
        objc_registerClassPair(dynamic);
        @autoreleasepool {
            id instance = [dynamic new];
            for (int pass = 0; pass < 8; ++pass) {
                for (auto selector : selectors) {
                    assert(((int (*)(id, SEL))objc_msgSend)(instance, selector) == 64);
                }
            }
        }
        objc_disposeClassPair(dynamic);
    }
    puts("PASS: register/stack arguments, FP varargs, aggregate arguments/returns, super, resolution, forwarding, Block IMPs and cache growth");
}
