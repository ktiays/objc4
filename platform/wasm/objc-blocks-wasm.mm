#include "objc-private.h"
#include <Block_private.h>

@interface ObjC4WasmBlock : NSObject
@end
@implementation ObjC4WasmBlock
- (id)retain { return (id)_Block_copy(self); }
- (oneway void)release { _Block_release(self); }
- (id)autorelease { return _objc_rootAutorelease(self); }
- (id)copy { return (id)_Block_copy(self); }
- (id)copyWithZone:(struct _NSZone *)zone { return (id)_Block_copy(self); }
- (BOOL)allowsWeakReference { return !_Block_isDeallocating(self); }
- (BOOL)retainWeakReference { return _Block_tryRetain(self); }
@end
@interface ObjC4WasmStackBlock : ObjC4WasmBlock @end
@implementation ObjC4WasmStackBlock @end
@interface ObjC4WasmHeapBlock : ObjC4WasmBlock @end
@implementation ObjC4WasmHeapBlock @end
@interface ObjC4WasmGlobalBlock : ObjC4WasmBlock @end
@implementation ObjC4WasmGlobalBlock @end

asm(".global _NSConcreteStackBlock\n"
    ".set _NSConcreteStackBlock, OBJC_CLASS_$_ObjC4WasmStackBlock\n"
    ".global _NSConcreteMallocBlock\n"
    ".set _NSConcreteMallocBlock, OBJC_CLASS_$_ObjC4WasmHeapBlock\n"
    ".global _NSConcreteGlobalBlock\n"
    ".set _NSConcreteGlobalBlock, OBJC_CLASS_$_ObjC4WasmGlobalBlock\n"
    ".global _NSConcreteAutoBlock\n"
    ".set _NSConcreteAutoBlock, OBJC_CLASS_$_ObjC4WasmHeapBlock\n"
    ".global _NSConcreteFinalizingBlock\n"
    ".set _NSConcreteFinalizingBlock, OBJC_CLASS_$_ObjC4WasmHeapBlock\n"
    ".global _NSConcreteWeakBlockVariable\n"
    ".set _NSConcreteWeakBlockVariable, OBJC_CLASS_$_ObjC4WasmBlock\n");

extern "C" void objc_wasm_blocks_init() {
    Block_callbacks_RR callbacks = {
        sizeof(Block_callbacks_RR),
        [](const void *object) { objc_retain((id)object); },
        [](const void *object) { objc_release((id)object); },
        [](const void *object) { objc_destructInstance((id)object); }
    };
    _Block_use_RR2(&callbacks);
}
