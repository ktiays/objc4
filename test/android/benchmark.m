#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <assert.h>

@interface BenchmarkProbe : NSObject
- (uint64_t)add:(uint64_t)a to:(uint64_t)b;
@end
@implementation BenchmarkProbe
- (uint64_t)add:(uint64_t)a to:(uint64_t)b { return a + b; }
@end

static uint64_t now(void) {
    struct timespec time; clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * 1000000000 + time.tv_nsec;
}
static BenchmarkProbe *probe;
typedef uint64_t (*AddIMP)(id, SEL, uint64_t, uint64_t);
static AddIMP direct;
static SEL selector;
static volatile uint64_t sink;

static uint64_t runMessages(uint64_t count) {
    uint64_t result = 0;
    for (uint64_t i = 0; i < count; ++i) { result += [probe add:i to:1]; }
    return result;
}
static void *parallelMessages(void *context) {
    uint64_t count = *(uint64_t *)context;
    return (void *)(uintptr_t)runMessages(count);
}
static int compare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

int main(int argc, char **argv) {
    uint64_t count = argc > 1 ? strtoull(argv[1], NULL, 10) : 1000000;
    if (count < 4 || count > 100000000) { return 2; }
    enum { samples = 7, threads = 4 };
    double message[samples], imp[samples], parallel[samples];
    @autoreleasepool {
        probe = [BenchmarkProbe new];
        selector = @selector(add:to:);
        direct = (AddIMP)class_getMethodImplementation([BenchmarkProbe class], selector);
        sink = runMessages(10000);
        for (int sample = 0; sample < samples; ++sample) {
            uint64_t start = now();
            sink = runMessages(count);
            message[sample] = (double)(now() - start) / count;
            assert(sink == count * (count + 1) / 2);
            uint64_t result = 0;
            start = now();
            for (uint64_t i = 0; i < count; ++i) { result += direct(probe, selector, i, 1); }
            sink = result;
            imp[sample] = (double)(now() - start) / count;
            assert(sink == count * (count + 1) / 2);
            pthread_t workers[threads]; uint64_t perThread = count / threads;
            start = now();
            for (int i = 0; i < threads; ++i) {
                assert(pthread_create(&workers[i], NULL, parallelMessages, &perThread) == 0);
            }
            for (int i = 0; i < threads; ++i) {
                void *result; assert(pthread_join(workers[i], &result) == 0);
                sink = (uintptr_t)result;
                assert(sink == perThread * (perThread + 1) / 2);
            }
            parallel[sample] = (double)(now() - start) / (perThread * threads);
        }
        qsort(message, samples, sizeof(double), compare);
        qsort(imp, samples, sizeof(double), compare);
        qsort(parallel, samples, sizeof(double), compare);
        printf("mode=%s iterations=%llu samples=%d median_ns_per_call=%.2f "
               "direct_imp_ns=%.2f four_thread_ns_per_call=%.2f\n",
               OBJC_ANDROID_CACHE_FASTPATH ? "guarded-cache" : "forced-slow-path",
               (unsigned long long)count, samples, message[samples / 2],
               imp[samples / 2], parallel[samples / 2]);
        probe = nil;
    }
    return 0;
}
