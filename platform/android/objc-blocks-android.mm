#include "objc-private.h"
#include <Block_private.h>

// Supply actual objc4 classes for the compiler's Blocks ABI symbols. This
// replaces only BlocksRuntime's placeholder data.c arrays, not its algorithms.
@interface ObjC4AndroidBlock : NSObject
@end
@implementation ObjC4AndroidBlock
- (id)retain { return (id)_Block_copy(self); }
- (oneway void)release { _Block_release(self); }
- (id)autorelease { return _objc_rootAutorelease(self); }
- (id)copy { return (id)_Block_copy(self); }
- (id)copyWithZone:(struct _NSZone *)zone { return (id)_Block_copy(self); }
- (BOOL)allowsWeakReference { return !_Block_isDeallocating(self); }
- (BOOL)retainWeakReference { return _Block_tryRetain(self); }
@end
@interface ObjC4AndroidStackBlock : ObjC4AndroidBlock @end
@implementation ObjC4AndroidStackBlock @end
@interface ObjC4AndroidHeapBlock : ObjC4AndroidBlock @end
@implementation ObjC4AndroidHeapBlock @end
@interface ObjC4AndroidGlobalBlock : ObjC4AndroidBlock @end
@implementation ObjC4AndroidGlobalBlock @end

asm(".global _NSConcreteStackBlock\n"
    ".set _NSConcreteStackBlock, OBJC_CLASS_$_ObjC4AndroidStackBlock\n"
    ".global _NSConcreteMallocBlock\n"
    ".set _NSConcreteMallocBlock, OBJC_CLASS_$_ObjC4AndroidHeapBlock\n"
    ".global _NSConcreteGlobalBlock\n"
    ".set _NSConcreteGlobalBlock, OBJC_CLASS_$_ObjC4AndroidGlobalBlock\n"
    ".global _NSConcreteAutoBlock\n"
    ".set _NSConcreteAutoBlock, OBJC_CLASS_$_ObjC4AndroidHeapBlock\n"
    ".global _NSConcreteFinalizingBlock\n"
    ".set _NSConcreteFinalizingBlock, OBJC_CLASS_$_ObjC4AndroidHeapBlock\n"
    ".global _NSConcreteWeakBlockVariable\n"
    ".set _NSConcreteWeakBlockVariable, OBJC_CLASS_$_ObjC4AndroidBlock\n");

void objc_android_blocks_init() {
    Block_callbacks_RR callbacks = {
        sizeof(Block_callbacks_RR),
        [](const void *object) { objc_retain((id)object); },
        [](const void *object) { objc_release((id)object); },
        [](const void *object) { objc_destructInstance((id)object); }
    };
    _Block_use_RR2(&callbacks);
}
