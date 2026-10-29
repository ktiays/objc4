#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <objc/android.h>
#include <assert.h>

void objc4_test_arc_unload(void) {
    objc_android_module_handle *handle = NULL;
    assert(objc_android_module_open("libobjc4-unload-plugin.so", &handle) == OBJC_ANDROID_MODULE_OK);
    assert(objc_android_module_acquire(handle) == OBJC_ANDROID_MODULE_OK);
    __weak id weak;
    @try {
        @autoreleasepool {
            Class cls = objc_getClass("AndroidUnloadProbe");
            id object = [cls new]; weak = object;
            SEL value = sel_registerName("value");
            IMP implementation = class_getMethodImplementation(cls, value);
            assert(((int (*)(id, SEL))implementation)(object, value) == 84);
            object = nil; assert(weak == nil);
            void *symbol = NULL;
            assert(objc_android_module_symbol(handle, "objc4_unload_block", &symbol) == OBJC_ANDROID_MODULE_OK);
            typedef int (^ModuleBlock)(void);
            ModuleBlock block = ((ModuleBlock (*)(void))symbol)();
            assert(block() == 84);
            assert(objc_android_module_close(handle) == OBJC_ANDROID_MODULE_BUSY_LEASES);
            block = nil;
            int caught = 0;
            @try { ((void (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("throwProbe")); }
            @catch (id exception) {
                assert(((int (*)(id, SEL))objc_msgSend)(exception, sel_registerName("value")) == 84);
                caught = 1;
            }
            assert(caught);
        }
    } @finally { assert(objc_android_module_release(handle) == OBJC_ANDROID_MODULE_OK); }
    assert(objc_android_module_close(handle) == OBJC_ANDROID_MODULE_OK);
    assert(objc_getClass("AndroidUnloadProbe") == Nil);
    assert(objc_android_module_destroy(handle) == OBJC_ANDROID_MODULE_OK);
}
