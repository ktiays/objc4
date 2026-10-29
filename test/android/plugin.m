#include <objc/NSObject.h>
static int loads;
@interface AndroidPlugin : NSObject
- (int)value;
@end
@implementation AndroidPlugin
+ (void)load { ++loads; }
- (int)value { return 42; }
@end
__attribute__((visibility("default")))
int objc4_android_plugin_load_count(void) { return loads; }
