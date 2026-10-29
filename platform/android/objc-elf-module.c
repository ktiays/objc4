#include <objc/android.h>

#define SECTION(name) \
    extern char __start_##name[] __attribute__((visibility("hidden"))); \
    extern char __stop_##name[] __attribute__((visibility("hidden")));
SECTION(objc_selrefs)
SECTION(objc_msgrefs)
SECTION(objc_classrefs)
SECTION(objc_superrefs)
SECTION(objc_protorefs)
SECTION(objc_classlist)
SECTION(objc_nlclslist)
SECTION(objc_stublist)
SECTION(objc_catlist)
SECTION(objc_catlist2)
SECTION(objc_nlcatlist)
SECTION(objc_protolist)
SECTION(objc_fork_ok)
SECTION(objc_rawisa)
SECTION(objc_imageinfo)
#undef SECTION

static struct objc_android_module module;

static const struct objc_android_module *module_descriptor(void) {
    module.version = OBJC_ANDROID_MODULE_VERSION;
#define SET(index, name) \
    module.sections[index].data = __start_##name; \
    module.sections[index].size = (size_t)(__stop_##name - __start_##name);
    SET(0, objc_selrefs)
    SET(1, objc_msgrefs)
    SET(2, objc_classrefs)
    SET(3, objc_superrefs)
    SET(4, objc_protorefs)
    SET(5, objc_classlist)
    SET(6, objc_nlclslist)
    SET(7, objc_stublist)
    SET(8, objc_catlist)
    SET(9, objc_catlist2)
    SET(10, objc_nlcatlist)
    SET(11, objc_protolist)
    SET(12, objc_fork_ok)
    SET(13, objc_rawisa)
    SET(14, objc_imageinfo)
#undef SET
    return &module;
}

#ifdef OBJC_ANDROID_RUNTIME_IMAGE
// A dependent image registers the runtime after its ELF C++ initializers ran.
const struct objc_android_module *objc_android_runtime_module(void) {
    return module_descriptor();
}
#else
__attribute__((constructor(101)))
static void register_objc_module(void) {
    objc_android_register_module(module_descriptor());
}
#endif
