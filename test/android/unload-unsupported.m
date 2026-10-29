#include <objc/NSObject.h>
@protocol AndroidUnloadUnsupportedProtocol
- (int)unsupportedValue;
@end
@interface NSObject (AndroidUnloadUnsupported)
- (int)unsupportedCategory;
@end
@implementation NSObject (AndroidUnloadUnsupported)
- (int)unsupportedCategory { return 1; }
@end
@interface AndroidUnloadUnsupported : NSObject <AndroidUnloadUnsupportedProtocol> @end
@implementation AndroidUnloadUnsupported
- (int)unsupportedValue { return 1; }
@end
