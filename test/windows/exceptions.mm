#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <assert.h>
#include <stdio.h>
#include <exception>

@interface WindowsException : NSObject @end
@implementation WindowsException @end
@interface WindowsSubException : WindowsException @end
@implementation WindowsSubException @end

static int cleanups;
struct Cleanup { ~Cleanup() { ++cleanups; } };

static void throwObject(id object) {
    Cleanup cleanup;
    @throw object;
}
static int returnThroughFinally(bool exceptional) {
    @try {
        if (exceptional) { @throw [WindowsException new]; }
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
    @try { @throw [WindowsException new]; }
    @finally { return 9; }
}

@interface WindowsThrowingInitializer : NSObject @end
@implementation WindowsThrowingInitializer
+ (void)initialize { @throw [WindowsException new]; }
@end

int main() {
    @autoreleasepool {
        WindowsSubException *exception = [WindowsSubException new];
        bool caught = false;
        @try { throwObject(exception); }
        @catch (WindowsThrowingInitializer *) { assert(false); }
        @catch (WindowsException *value) { assert(value == exception); caught = true; }
        assert(caught && cleanups == 1);
        caught = false;
        @try {
            @try { @throw exception; }
            @catch (id value) { assert(value == exception); @throw; }
            @finally { ++cleanups; }
        } @catch (WindowsSubException *value) { assert(value == exception); caught = true; }
        assert(caught && cleanups == 2);
        try {
            @try { Cleanup cleanup; throw 42; }
            @catch (id) { assert(false); }
            @finally { ++cleanups; }
        } catch (int value) { assert(value == 42); }
        assert(cleanups == 4);
        assert(returnThroughFinally(false) == 4);
        @try { returnThroughFinally(true); }
        @catch (WindowsException *) {}
        assert(cleanups == 6);
        assert(replaceReturn() == 7);
        assert(suppressException() == 9);
        assert(std::uncaught_exceptions() == 0);
        @try { (void)[WindowsThrowingInitializer new]; }
        @catch (WindowsException *) { caught = true; }
        assert(caught);
        // The throwing +initialize has completed, so the next send succeeds.
        assert([WindowsThrowingInitializer new] != nil);
        @try { @synchronized(exception) { @throw exception; } }
        @catch (id) {}
        @synchronized(exception) { ++cleanups; }
    }
    puts("PASS: typed ObjC exceptions, rethrow, finally, C++ unwinding, initialize and synchronized cleanup");
}
