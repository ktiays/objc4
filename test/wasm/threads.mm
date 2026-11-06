#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <objc/wasm.h>
#include <pthread.h>
#include <atomic>
#include <assert.h>
#include <stdio.h>

@interface WasmThreadProbe : NSObject
- (int)value:(int)value;
@end
@implementation WasmThreadProbe
- (int)value:(int)value { return value + 1; }
@end

static pthread_barrier_t barrier;
static std::atomic<IMP> published;
static WasmThreadProbe *probe;
static IMP original;
static std::atomic<int> completions;

static int alternate(id object, SEL selector, int value) { return value + 2; }
static void *worker(void *context) {
    uintptr_t index = uintptr_t(context);
    @autoreleasepool {
        pthread_barrier_wait(&barrier);
        if (index == 0) {
            IMP implementation = imp_implementationWithBlock(^(id receiver, int value) { return value + 40; });
            published.store(implementation, std::memory_order_release);
        }
        pthread_barrier_wait(&barrier);
        IMP implementation = published.load(std::memory_order_acquire);
        for (int iteration = 0; iteration < 3000; ++iteration) {
            assert(((int (*)(id, SEL, int))implementation)(probe, @selector(value:), 2) == 42);
            int value = [probe value:40];
            assert(value == 41 || value == 42);
            if (index == 1 && iteration % 7 == 0) {
                class_replaceMethod([WasmThreadProbe class], @selector(value:),
                    iteration % 2 ? original : (IMP)alternate, "i@:i");
            }
            if (iteration % 30 == 0) {
                IMP temporary = imp_implementationWithBlock(^(id receiver, int value) { return value + int(index); });
                assert(((int (*)(id, SEL, int))temporary)(probe, @selector(value:), 2) == 2 + index);
                assert(imp_removeBlock(temporary));
                __weak id weak;
                @autoreleasepool {
                    id object = [WasmThreadProbe new];
                    weak = object;
                }
                assert(weak == nil);
            }
        }
    }
    ++completions;
    return nullptr;
}

int main() {
    @autoreleasepool {
        probe = [WasmThreadProbe new];
        original = class_getMethodImplementation([WasmThreadProbe class], @selector(value:));
        assert(pthread_barrier_init(&barrier, nullptr, 4) == 0);
        pthread_t threads[4];
        for (uintptr_t index = 0; index < 4; ++index) {
            assert(pthread_create(&threads[index], nullptr, worker, (void *)index) == 0);
        }
        for (auto thread : threads) { assert(pthread_join(thread, nullptr) == 0); }
        assert(completions == 4);
        assert(imp_removeBlock(published.load()));
        pthread_barrier_destroy(&barrier);
        probe = nil;
    }
    puts("PASS: pthread cache mutation, Worker-created Block IMP publication, recycling, ARC and weak references");
}
