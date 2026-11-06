#pragma once

void objc_wasm_cache_write_begin(const void *cls);
void objc_wasm_cache_write_end(const void *cls);

class objc_wasm_cache_writer {
    const void *cls;
public:
    explicit objc_wasm_cache_writer(const void *value) : cls(value) {
        objc_wasm_cache_write_begin(cls);
    }
    ~objc_wasm_cache_writer() { objc_wasm_cache_write_end(cls); }
    objc_wasm_cache_writer(const objc_wasm_cache_writer &) = delete;
    objc_wasm_cache_writer &operator=(const objc_wasm_cache_writer &) = delete;
};
