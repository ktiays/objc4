#include "objc-private.h"
#include <objc/wasm.h>
#include <Block_private.h>
#include <dlfcn.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

extern "C" int objc_wasm_prepare_adapter(const char *path, const char *signature,
                                         int blockAdapter);
extern "C" void objc_wasm_discard_adapter_file(const char *path);
extern void objc_defaultForwardHandler(id, SEL);
extern void (*_objc_forward_handler)(id, SEL);

namespace {
struct BlockABI { void *invoke; const char *signature; };
extern "C" BlockABI __start_objc_wasm_block_abis[] __attribute__((weak));
extern "C" BlockABI __stop_objc_wasm_block_abis[] __attribute__((weak));

struct Binding {
    std::string signature;
    IMP implementation = nullptr;
    void (*invoke)(void *, void *, IMP) = nullptr;
    uintptr_t *cell = nullptr;
    id block = nil;
};
struct Registry {
    std::mutex lock;
    std::unordered_map<void *, const char *> blockABIs;
    std::unordered_map<IMP, Binding *> activeBlocks;
    std::unordered_map<std::string, std::vector<Binding *>> freeBlocks;
    std::unordered_map<std::string, Binding *> forwarders;
    std::unordered_set<std::string> templates;
    std::vector<std::unique_ptr<Binding>> bindings;
    std::atomic<size_t> nextIdentifier{0};

    Registry() {
        for (auto *abi = __start_objc_wasm_block_abis;
             abi && abi < __stop_objc_wasm_block_abis; ++abi) {
            blockABIs.emplace(abi->invoke, abi->signature);
        }
    }
};
Registry &registry() { static Registry value; return value; }
std::atomic<objc_wasm_forward_handler> forwardHandler{nullptr};

unsigned receiverIndex(const char *signature) {
    const char *flags = strchr(signature, ':');
    return flags && (strtoul(flags + 1, nullptr, 10) & 1) ? 1 : 0;
}

// Emscripten's dlopen event stream publishes the same table slot in every
// Worker, including sleeping Workers when they wake and newly created Workers.
// Instances remain installed and are recycled per signature. This avoids both
// a fixed trampoline pool and unbounded growth when Block IMPs are removed.
std::unique_ptr<Binding> createBinding(const std::string &signature, bool block) {
    auto binding = std::make_unique<Binding>();
    binding->signature = signature;
    std::string path = "/__objc4_adapter_" + std::to_string(registry().nextIdentifier++) +
                       (block ? "_b_" : "_f_") + signature + ".wasm";
    if (!objc_wasm_prepare_adapter(path.c_str(), signature.c_str(), block)) {
        _objc_fatal("Could not generate a WebAssembly adapter for %s", signature.c_str());
    }
    void *handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    objc_wasm_discard_adapter_file(path.c_str());
    if (!handle) { _objc_fatal("WebAssembly adapter load failed: %s", dlerror()); }
    binding->cell = static_cast<uintptr_t *>(dlsym(handle, "objc_context"));
    binding->implementation = reinterpret_cast<IMP>(dlsym(handle, "objc_adapter"));
    if (!block) {
        binding->invoke = reinterpret_cast<void (*)(void *, void *, IMP)>(
            dlsym(handle, "objc_invoke"));
    }
    if (!binding->cell || !binding->implementation || (!block && !binding->invoke)) {
        _objc_fatal("Incomplete WebAssembly adapter exports");
    }
    if (!block) {
        __atomic_store_n(binding->cell, uintptr_t(binding.get()), __ATOMIC_RELEASE);
    }
    return binding;
}
}

// These are cache sentinels. Typed calls to forwarding are routed through a
// generated adapter by objc_wasm_lookup, where the calling ABI is available.
void _objc_msgForward_impcache() {
    _objc_fatal("A forwarding sentinel was called without an ABI signature");
}
void _objc_msgForward() {
    _objc_fatal("Use a typed message send or objc_wasm_invocation_invoke for forwarding");
}
void _objc_msgForward_stret() { _objc_fatal("Untyped forwarding entry"); }

// An escaped dispatcher is recognized at its eventual typed call by Clang.
// No untyped entry can preserve an arbitrary Wasm function signature.
extern "C" {
void objc_msgSend() { _objc_fatal("objc_msgSend requires the patched Wasm compiler"); }
// Distinct observable bodies preserve marker identity under function merging.
void objc_msgSend_stret() { _objc_fatal("Untyped objc_msgSend_stret entry"); }
void objc_msgSend_fpret() { _objc_fatal("Untyped objc_msgSend_fpret entry"); }
void objc_msgSend_fp2ret() { _objc_fatal("Untyped objc_msgSend_fp2ret entry"); }
void objc_msgSendSuper() { _objc_fatal("Untyped objc_msgSendSuper entry"); }
void objc_msgSendSuper_stret() { _objc_fatal("Untyped objc_msgSendSuper_stret entry"); }
id objc_msgSendSuper2(struct objc_super *, SEL, ...) { _objc_fatal("Untyped objc_msgSendSuper2 entry"); }
void objc_msgSendSuper2_stret(struct objc_super *, SEL, ...) { _objc_fatal("Untyped objc_msgSendSuper2_stret entry"); }
}

extern "C" IMP objc_wasm_forward_imp(const char *signature) {
    auto &state = registry();
    {
        std::lock_guard lock(state.lock);
        auto found = state.forwarders.find(signature);
        if (found != state.forwarders.end()) { return found->second->implementation; }
    }
    auto binding = createBinding(signature, false);
    std::lock_guard lock(state.lock);
    // Concurrent misses may create two bindings; both remain valid. Future
    // misses use the first one, without holding our mutex across dlopen.
    auto [position, inserted] = state.forwarders.emplace(signature, binding.get());
    state.templates.insert("f:" + binding->signature);
    state.bindings.push_back(std::move(binding));
    return position->second->implementation;
}

IMP imp_implementationWithBlock(id block) {
    objc_wasm_init();
    auto &state = registry();
    std::string signature;
    Binding *binding = nullptr;
    void *invoke = reinterpret_cast<void *>(reinterpret_cast<Block_layout *>(block)->invoke);
    {
        std::lock_guard lock(state.lock);
        auto abi = state.blockABIs.find(invoke);
        if (abi == state.blockABIs.end()) {
            _objc_fatal("Block ABI metadata is missing; compile this Block with the patched Clang");
        }
        signature = abi->second;
        auto &available = state.freeBlocks[signature];
        if (!available.empty()) { binding = available.back(); available.pop_back(); }
    }
    if (!binding) {
        auto created = createBinding(signature, true);
        binding = created.get();
        std::lock_guard lock(state.lock);
        state.templates.insert("b:" + signature);
        state.bindings.push_back(std::move(created));
    }
    id copied = (id)_Block_copy(block);
    {
        std::lock_guard lock(state.lock);
        binding->block = copied;
        __atomic_store_n(binding->cell, uintptr_t(copied), __ATOMIC_RELEASE);
        state.activeBlocks.emplace(binding->implementation, binding);
    }
    return binding->implementation;
}
id imp_getBlock(IMP implementation) {
    auto &state = registry();
    std::lock_guard lock(state.lock);
    auto found = state.activeBlocks.find(implementation);
    return found == state.activeBlocks.end() ? nil : found->second->block;
}
BOOL imp_removeBlock(IMP implementation) {
    auto &state = registry();
    id block;
    {
        std::lock_guard lock(state.lock);
        auto found = state.activeBlocks.find(implementation);
        if (found == state.activeBlocks.end()) { return NO; }
        Binding *binding = found->second;
        block = binding->block;
        binding->block = nil;
        __atomic_store_n(binding->cell, uintptr_t(0), __ATOMIC_RELEASE);
        state.activeBlocks.erase(found);
        state.freeBlocks[binding->signature].push_back(binding);
    }
    _Block_release(block);
    return YES;
}

objc_wasm_forward_handler objc_wasm_set_forward_handler(objc_wasm_forward_handler fn) {
    return forwardHandler.exchange(fn);
}
void objc_wasm_invocation_invoke(objc_wasm_invocation *invocation, id receiver,
                                IMP implementation) {
    auto index = receiverIndex(invocation->abi_signature);
    auto *slots = static_cast<uint64_t *>(invocation->arguments);
    slots[index] = uintptr_t(receiver);
    if (!receiver) {
        memset(invocation->result, 0, 8);
        if (index) {
            size_t size = strtoul(strrchr(invocation->abi_signature, ':') + 1, nullptr, 10);
            memset(reinterpret_cast<void *>(uintptr_t(slots[0])), 0, size);
        }
        return;
    }
    SEL selector = reinterpret_cast<SEL>(uintptr_t(slots[index + 1]));
    if (!implementation) {
        implementation = lookUpImpOrForwardTryCache(receiver, selector,
            object_getClass(receiver), LOOKUP_INITIALIZE | LOOKUP_RESOLVER);
        if (implementation == (IMP)_objc_msgForward_impcache || implementation == (IMP)_objc_msgForward) {
            implementation = objc_wasm_forward_imp(invocation->abi_signature);
        }
    }
    invocation->invoke(invocation->arguments, invocation->result, implementation);
}

extern "C" __attribute__((visibility("default")))
void objc_wasm_forward_invoke(uintptr_t context, void *arguments, void *result) {
    auto &binding = *reinterpret_cast<Binding *>(context);
    objc_wasm_invocation invocation = {binding.signature.c_str(), arguments, result, binding.invoke};
    auto index = receiverIndex(invocation.abi_signature);
    auto *slots = static_cast<uint64_t *>(arguments);
    id receiver = (id)uintptr_t(slots[index]);
    SEL selector = reinterpret_cast<SEL>(uintptr_t(slots[index + 1]));
    // Fast forwarding uses ordinary Objective-C methods before the full
    // invocation hook, matching NSObject's forwardingTargetForSelector: path.
    SEL targetSelector = sel_registerName("forwardingTargetForSelector:");
    IMP targetIMP = lookUpImpOrForwardTryCache(receiver, targetSelector,
        object_getClass(receiver), LOOKUP_INITIALIZE | LOOKUP_RESOLVER | LOOKUP_NIL);
    if (targetIMP) {
        id target = reinterpret_cast<id (*)(id, SEL, SEL)>(targetIMP)(receiver, targetSelector, selector);
        if (target && target != receiver) {
            objc_wasm_invocation_invoke(&invocation, target, nullptr);
            return;
        }
    }
    if (auto handler = forwardHandler.load()) { handler(&invocation); return; }
    if (_objc_forward_handler != objc_defaultForwardHandler) {
        invocation.invoke(arguments, result, (IMP)_objc_forward_handler);
        return;
    }
    objc_defaultForwardHandler(receiver, selector);
}
void objc_wasm_get_adapter_statistics(objc_wasm_adapter_statistics *out) {
    auto &state = registry();
    std::lock_guard lock(state.lock);
    *out = {state.templates.size(), state.bindings.size(), state.activeBlocks.size()};
}
