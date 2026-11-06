#pragma once

void objc_windows_cache_write_begin(const void *cls);
void objc_windows_cache_write_end(const void *cls);

class objc_windows_cache_writer {
    const void *cls;
public:
    explicit objc_windows_cache_writer(const void *value) : cls(value) {
        objc_windows_cache_write_begin(cls);
    }
    ~objc_windows_cache_writer() { objc_windows_cache_write_end(cls); }
    objc_windows_cache_writer(const objc_windows_cache_writer &) = delete;
    objc_windows_cache_writer &operator=(const objc_windows_cache_writer &) = delete;
};
