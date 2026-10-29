/* Keep compiler-emitted ObjC metadata even under --gc-sections/LTO. */
SECTIONS {
  objc_selrefs : ALIGN(8) { HIDDEN(__start_objc_selrefs = .); KEEP(*(objc_selrefs)) HIDDEN(__stop_objc_selrefs = .); }
  objc_msgrefs : ALIGN(8) { HIDDEN(__start_objc_msgrefs = .); KEEP(*(objc_msgrefs)) HIDDEN(__stop_objc_msgrefs = .); }
  objc_classrefs : ALIGN(8) { HIDDEN(__start_objc_classrefs = .); KEEP(*(objc_classrefs)) HIDDEN(__stop_objc_classrefs = .); }
  objc_superrefs : ALIGN(8) { HIDDEN(__start_objc_superrefs = .); KEEP(*(objc_superrefs)) HIDDEN(__stop_objc_superrefs = .); }
  objc_protorefs : ALIGN(8) { HIDDEN(__start_objc_protorefs = .); KEEP(*(objc_protorefs)) HIDDEN(__stop_objc_protorefs = .); }
  objc_classlist : ALIGN(8) { HIDDEN(__start_objc_classlist = .); KEEP(*(objc_classlist)) HIDDEN(__stop_objc_classlist = .); }
  objc_nlclslist : ALIGN(8) { HIDDEN(__start_objc_nlclslist = .); KEEP(*(objc_nlclslist)) HIDDEN(__stop_objc_nlclslist = .); }
  objc_stublist : ALIGN(8) { HIDDEN(__start_objc_stublist = .); KEEP(*(objc_stublist)) HIDDEN(__stop_objc_stublist = .); }
  objc_catlist : ALIGN(8) { HIDDEN(__start_objc_catlist = .); KEEP(*(objc_catlist)) HIDDEN(__stop_objc_catlist = .); }
  objc_catlist2 : ALIGN(8) { HIDDEN(__start_objc_catlist2 = .); KEEP(*(objc_catlist2)) HIDDEN(__stop_objc_catlist2 = .); }
  objc_nlcatlist : ALIGN(8) { HIDDEN(__start_objc_nlcatlist = .); KEEP(*(objc_nlcatlist)) HIDDEN(__stop_objc_nlcatlist = .); }
  objc_protolist : ALIGN(8) { HIDDEN(__start_objc_protolist = .); KEEP(*(objc_protolist)) HIDDEN(__stop_objc_protolist = .); }
  objc_fork_ok : ALIGN(8) { HIDDEN(__start_objc_fork_ok = .); KEEP(*(objc_fork_ok)) HIDDEN(__stop_objc_fork_ok = .); }
  objc_rawisa : ALIGN(8) { HIDDEN(__start_objc_rawisa = .); KEEP(*(objc_rawisa)) HIDDEN(__stop_objc_rawisa = .); }
  objc_imageinfo : ALIGN(8) { HIDDEN(__start_objc_imageinfo = .); KEEP(*(objc_imageinfo)) HIDDEN(__stop_objc_imageinfo = .); }
} INSERT AFTER .data;
