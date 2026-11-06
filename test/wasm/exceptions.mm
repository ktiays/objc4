#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <assert.h>
#include <stdio.h>
#include <exception>

@interface WasmException : NSObject @end
@implementation WasmException @end
@interface WasmSubException : WasmException @end
@implementation WasmSubException @end

static int cleanups;
struct Cleanup { ~Cleanup() { ++cleanups; } };

static void throwObject(id object) {
    Cleanup cleanup;
    @throw object;
}
static int returnThroughFinally(bool exceptional) {
    @try {
        if (exceptional) { @throw [WasmException new]; }
        return 4;
    } @finally {
        ++cleanups;
    }
}
static int replaceReturn() {
    @try { return 4; }
    @finally { return 7; }
}
static int suppressException() {
    @try { @throw [WasmException new]; }
    @finally { return 9; }
}

@interface WasmThrowingInitializer : NSObject @end
@implementation WasmThrowingInitializer
+ (void)initialize { @throw [WasmException new]; }
@end

int main() {
    @autoreleasepool {
        WasmSubException *exception = [WasmSubException new];
        bool caught = false;
        @try { throwObject(exception); }
        @catch (WasmThrowingInitializer *) { assert(false); }
        @catch (WasmException *value) { assert(value == exception); caught = true; }
        assert(caught && cleanups == 1);
        caught = false;
        @try {
            @try { @throw exception; }
            @catch (id value) { assert(value == exception); @throw; }
            @finally { ++cleanups; }
        } @catch (WasmSubException *value) { assert(value == exception); caught = true; }
        assert(caught && cleanups == 2);
        try {
            @try { Cleanup cleanup; throw 42; }
            @catch (id) { assert(false); }
            @finally { ++cleanups; }
        } catch (int value) { assert(value == 42); }
        assert(cleanups == 4);
        assert(returnThroughFinally(false) == 4);
        @try { returnThroughFinally(true); }
        @catch (WasmException *) {}
        assert(cleanups == 6);
        assert(replaceReturn() == 7);
        assert(suppressException() == 9);
        assert(std::uncaught_exceptions() == 0);
        @try { (void)[WasmThrowingInitializer new]; }
        @catch (WasmException *) { caught = true; }
        assert(caught);
        // The throwing +initialize has completed, so the next send succeeds.
        assert([WasmThrowingInitializer new] != nil);
        @try { @synchronized(exception) { @throw exception; } }
        @catch (id) {}
        @synchronized(exception) { ++cleanups; }
    }
    puts("PASS: typed ObjC exceptions, rethrow, finally, C++ unwinding, initialize and synchronized cleanup");
}
