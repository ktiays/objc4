#pragma once
#include <stdint.h>

// Source-compatibility tag for objc4's image APIs. On Android this is a
// runtime-owned module descriptor, never a pointer to an ELF or Mach-O header.
// Keeping the historical tag avoids changing the public image callback ABI.
struct mach_header {
    uint32_t filetype;
};
#define MH_EXECUTE 2
#define MH_DYLIB 6
#define MH_BUNDLE 8
