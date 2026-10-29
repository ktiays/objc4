#pragma once
#include <stdbool.h>

static inline bool OSAtomicCompareAndSwapPtr(void *oldValue, void *newValue,
                                             void *volatile *address) {
    return __atomic_compare_exchange_n(address, &oldValue, newValue, false,
                                        __ATOMIC_RELAXED, __ATOMIC_RELAXED);
}
static inline bool OSAtomicCompareAndSwapPtrBarrier(void *oldValue, void *newValue,
                                                    void *volatile *address) {
    return __atomic_compare_exchange_n(address, &oldValue, newValue, false,
                                        __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}
