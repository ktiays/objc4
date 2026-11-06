#include <objc/windows.h>

// COFF sorts contributions with the same prefix by their $ suffix. Bounds
// must be emitted into every executable/DLL, alongside Clang's $B metadata.
#define SECTION(name) \
    static void *name##_begin __attribute__((used, section("." #name "$A"), aligned(8))); \
    static void *name##_end __attribute__((used, section("." #name "$Z"), aligned(8)));
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

__attribute__((constructor))
static void registerImage(void) {
#define BOUNDS(name) {(char *)&name##_begin + sizeof(void *), \
    (size_t)((char *)&name##_end - (char *)&name##_begin - sizeof(void *))}
    const struct objc_windows_section sections[] = {
        BOUNDS(objc_selrefs), BOUNDS(objc_msgrefs), BOUNDS(objc_classrefs),
        BOUNDS(objc_superrefs), BOUNDS(objc_protorefs), BOUNDS(objc_classlist),
        BOUNDS(objc_nlclslist), BOUNDS(objc_stublist), BOUNDS(objc_catlist),
        BOUNDS(objc_catlist2), BOUNDS(objc_nlcatlist), BOUNDS(objc_protolist),
        BOUNDS(objc_fork_ok), BOUNDS(objc_rawisa), BOUNDS(objc_imageinfo)
    };
#undef BOUNDS
    objc_windows_register_image(&objc_selrefs_begin, sections);
}
