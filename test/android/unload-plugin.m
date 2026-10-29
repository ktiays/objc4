#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <sched.h>

static int loads;
static int initializes;
@interface AndroidUnloadProbe : NSObject
- (int)value;
- (int)androidUnloadUniqueSelector_951;
+ (int)waitUntil:(atomic_bool *)entered release:(atomic_bool *)release;
+ (void)throwProbe;
@end
@implementation AndroidUnloadProbe
+ (void)load { ++loads; }
+ (void)initialize {
    if (self == objc_getClass("AndroidUnloadProbe")) { ++initializes; }
}
- (int)value { return 84; }
- (int)androidUnloadUniqueSelector_951 { return 951; }
+ (int)waitUntil:(atomic_bool *)entered release:(atomic_bool *)release {
    atomic_store(entered, true);
    while (!atomic_load(release)) { sched_yield(); }
    return 84;
}
+ (void)throwProbe { @throw [self new]; }
@end
@interface AndroidUnloadChild : AndroidUnloadProbe @end
@implementation AndroidUnloadChild @end
@interface AndroidUnloadUnused : NSObject @end
@implementation AndroidUnloadUnused @end

__attribute__((visibility("default"))) int objc4_unload_load_count(void) { return loads; }
__attribute__((visibility("default"))) int objc4_unload_initialize_count(void) { return initializes; }
__attribute__((visibility("default"))) SEL objc4_unload_selector(void) {
    return @selector(androidUnloadUniqueSelector_951);
}
__attribute__((visibility("default"))) int (^objc4_unload_block(void))(void) {
    return ^{ return 84; };
}
