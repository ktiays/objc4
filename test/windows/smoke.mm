#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <assert.h>
#include <stdint.h>
#include <objc/NSObjCRuntime.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

static int loads;
static int initializes;
static int deallocations;
struct LargeResult { uint64_t values[5]; };

@protocol WindowsProtocol
- (int)add:(int)a to:(int)b;
@end

@interface WindowsProbe : NSObject <WindowsProtocol>
@property(nonatomic, strong) id child;
- (int)add:(int)a to:(int)b;
- (double)mix:(double)a with:(double)b;
- (struct LargeResult)large:(uint64_t)value;
- (int)sum:(int)count, ...;
@end

@interface WindowsProbe (Category)
- (int)categoryValue;
@end
@implementation WindowsProbe (Category)
+ (void)load { ++loads; }
- (int)categoryValue { return 42; }
@end

@implementation WindowsProbe
+ (void)load { ++loads; }
+ (void)initialize { if (self == objc_getClass("WindowsProbe")) { ++initializes; } }
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

@interface WindowsChild : WindowsProbe @end
@implementation WindowsChild
- (int)add:(int)a to:(int)b { return [super add:a to:b] + 10; }
@end

__attribute__((noinline))
static void *escapedDispatcher(int mode) {
    #if defined(__x86_64__)
    if (mode == 1) return (void *)objc_msgSend_stret;
#endif
    if (mode == 2) return (void *)objc_msgSendSuper;
    return (void *)objc_msgSend;
}

#include <windows.h>
int main(void) {
    static_assert(sizeof(NSInteger) == sizeof(void *));
    HMODULE plugin = LoadLibraryW(L"objc4-windows-plugin.dll");
    assert(plugin);
    Class pluginClass = objc_getClass("WindowsPlugin");
    assert(pluginClass);
    unsigned imageCount = 0;
    const char **imageNames = objc_copyImageNames(&imageCount);
    assert(imageNames && imageCount >= 3 && imageNames[imageCount] == nullptr);
    free(imageNames);
    const char *pluginImage = class_getImageName(pluginClass);
    assert(pluginImage && strstr(pluginImage, "objc4-windows-plugin.dll"));
    unsigned classCount = 0;
    const char **classNames = objc_copyClassNamesForImage(pluginImage, &classCount);
    assert(classNames && classCount == 1 && !strcmp(classNames[0], "WindowsPlugin"));
    free(classNames);
    id instance = [pluginClass new];
    auto pluginValue = (int (*)(id, SEL))objc_msgSend;
    assert(pluginValue(instance, sel_registerName("pluginValue")) == 73);
    FreeLibrary(plugin);
    assert(pluginValue(instance, sel_registerName("pluginValue")) == 73);
    assert(loads == 2);
    __weak WindowsProbe *weak;
    @autoreleasepool {
        WindowsProbe *probe = [WindowsProbe new];
        assert(initializes == 1);
        assert([probe conformsToProtocol:@protocol(WindowsProtocol)]);
        assert([probe categoryValue] == 42);
        assert(class_getProperty([WindowsProbe class], "child") != NULL);
        assert([probe add:12 to:30] == 42);
        auto send = (int (*)(id, SEL, int, int))escapedDispatcher(0);
        assert(send(probe, @selector(add:to:), 12, 30) == 42);
        assert([probe mix:1.25 with:2.5] == 5.0);
        assert(([probe sum:4, 1, 2, 3, 4] == 10));
        struct LargeResult large = [probe large:40];
        auto sendLarge = (struct LargeResult (*)(id, SEL, uint64_t))escapedDispatcher(1);
        large = sendLarge(probe, @selector(large:), 40);
        for (int index = 0; index < 5; ++index) {
            assert(large.values[index] == 40 + index);
        }
        WindowsChild *child = [WindowsChild new];
        assert([child add:12 to:30] == 52);
        struct objc_super superInfo = {child, [WindowsProbe class]};
        auto sendSuper = (int (*)(struct objc_super *, SEL, int, int))escapedDispatcher(2);
        assert(sendSuper(&superInfo, @selector(add:to:), 12, 30) == 42);
        WindowsProbe *missing = nil;
        assert([missing add:1 to:2] == 0);
        assert([missing mix:1 with:2] == 0.0);

        weak = probe;
        probe.child = [WindowsProbe new];
        static char associationKey;
        objc_setAssociatedObject(probe, &associationKey, probe.child,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        assert(objc_getAssociatedObject(probe, &associationKey) == probe.child);
    }
    assert(weak == nil);
    assert(deallocations >= 3);
    puts("PASS: Windows registration, load/initialize, integer/FP/struct, variadic, super, nil, ARC, weak and pools");
    return 0;
}
