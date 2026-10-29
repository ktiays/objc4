/*
 * Copyright (c) 2007 Apple Inc.  All Rights Reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */

// Shared lock initialization and ordering for all objc4 platform backends.
#pragma once

// Invoke `call` on each global lock in the runtime that's expected to be
// ordered with respect to other locks. The calls are made in the same order
// that the locks must be acquired in. This is also the set of locks that need
// to be locked/unlocked/reset in our atfork handlers.
template<typename Fn>
void forEachOrderedLock(const Fn &call) {
    // Helper that takes a function that enumerates a list of locks, and invokes
    // `call` with each lock returned, until the function starts returning NULL.
    auto callOnLocks = [&](auto getLock) {
        for (unsigned n = 0; auto lock = getLock(n); n++)
            call(lock);
    };

    // Helper that invokes `call` on each lock within a StripedMap.
    auto callOnStripedMap = [&](StripedMap<spinlock_t> &map) {
        map.forEach([&](spinlock_t &lock) {
            call(&lock);
        });
    };

    // Load methods run arbitrary code, so just about any runtime lock might be
    // acquired while it's held.
    call(&loadMethodLock);

    // PropertyLocks can be held when retaining a property, which can also run
    // arbitrary code. Similar for CppObjectLocks, which can be held when
    // copying a C++ object. StructLocks just does a memmove so its ordering
    // is less important, but we can put it with the other property locks.
    callOnStripedMap(PropertyLocks.get());
    callOnStripedMap(StructLocks.get());
    callOnStripedMap(CppObjectLocks.get());

    callOnLocks(_objc_sync_locks_get_lock);

    // AssociationsManagerLock can also be held when retaining ObjC objects or
    // copying C++ objects.
    call(&AssociationsManagerLock);

    // Runtime operations may occur inside SideTable locks (such as storeWeak
    // calling getMethodImplementation).
    callOnLocks(SideTableGetLock);

    call(&classInitLock);
    call(&pendingInitializeMapLock);

    // Some other operations may occur with runtimeLock held.
    call(&runtimeLock);
    call(&DemangleCacheLock);
    call(&selLock);
#if CONFIG_USE_CACHE_LOCK
    call(&cacheUpdateLock);
#endif
    call(&objcMsgLogLock);
    call(&AltHandlerDebugLock);

    // crashlog_lock comes at the end, on assumption that fatal errors could be
    // anywhere.
    call(&crashlog_lock);
}

// Check lock ordering.
#if LOCKDEBUG
bool lockdebug::lock_precedes_lock(const void *old_lock, const void *new_lock) {
    bool sawNewLock = false;
    bool result = false;
    forEachOrderedLock([&](const void *lock) {
        if (lock == old_lock && !sawNewLock)
            result = true;
        if (lock == new_lock)
            sawNewLock = true;
    });
    return result;
}
// LOCKDEBUG
#endif

static void locks_init(void)
{
    classInitLock.init();
    pendingInitializeMapLock.init();
    selLock.init();
    #if CONFIG_USE_CACHE_LOCK
    cacheUpdateLock.init();
    #endif
    loadMethodLock.init();
    crashlog_lock.init();
    objcMsgLogLock.init();
    AltHandlerDebugLock.init();
    AssociationsManagerLock.init();
    runtimeLock.init();
    DemangleCacheLock.init();
}
