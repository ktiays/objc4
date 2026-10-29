#pragma once

// Private hooks. The normal runtime paths immediately return when no opt-in
// unloadable images are loaded. Leases cover execution; these hooks additionally
// prevent closing a plugin while ordinary runtime-created instances survive.
void objc_android_track_object(id object, Class cls);
void objc_android_untrack_object(id object);
bool objc_android_class_has_associations(Class cls);
void objc_android_flush_caches_nolock();
bool objc_android_image_has_dependencies(header_info *,
    bool (*containsAddress)(const void *, const void *), const void *context);
