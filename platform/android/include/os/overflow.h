#pragma once
#define os_add_overflow(a, b, result) __builtin_add_overflow(a, b, result)
#define os_sub_overflow(a, b, result) __builtin_sub_overflow(a, b, result)
#define os_mul_overflow(a, b, result) __builtin_mul_overflow(a, b, result)
#define os_fastpath(x) __builtin_expect(!!(x), 1)
#define os_slowpath(x) __builtin_expect(!!(x), 0)
