#include <objc/NSObject.h>
@interface AndroidUnloadProbe : NSObject
- (int)value;
@end
@interface AndroidUnloadDependent : AndroidUnloadProbe @end
@implementation AndroidUnloadDependent @end
