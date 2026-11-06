// This library uses the pinned Emscripten dynamic linker to publish adapters
// consistently to pthread Workers. The runtime itself remains a static archive.
// The objc4 CMake integration exports the linker-synthesized __heap_base.
// Listing it as a JS stub dependency makes this SDK's lld check it before
// synthetic data-layout symbols have been created.
LibraryManager.library.$getMemory__deps = LibraryManager.library.$getMemory__deps.filter(
  dependency => dependency !== '__heap_base');

addToLibrary({
  $objc4Adapters__deps: ['$loadWebAssemblyModule', '$FS', '$UTF8ToString',
                        '$stackSave', '$stackAlloc', '$stackRestore',
                        'objc_wasm_forward_invoke'],
  $objc4Adapters__postset: 'objc4Adapters.install();',
  $objc4Adapters: {
    templates: new Map(),

    unsigned(value) {
      var bytes = [];
      do {
        var byte = value & 127;
        value = Math.floor(value / 128);
        bytes.push(byte | (value ? 128 : 0));
      } while (value);
      return bytes;
    },

    string(value) {
      // Adapter names and signatures use ASCII only.
      return [...this.unsigned(value.length), ...Array.from(value, c => c.charCodeAt(0))];
    },

    section(identifier, contents) {
      return [identifier, ...this.unsigned(contents.length), ...contents];
    },

    vector(values) {
      return [...this.unsigned(values.length), ...values.flat()];
    },

    create(signature, block) {
      var key = (block ? 'b:' : 'f:') + signature;
      if (this.templates.has(key)) return this.templates.get(key);
      var [result, flags, argumentString] = signature.split(':');
      var arguments_ = Array.from(argumentString);
      var valueTypes = {p: 0x7f, i: 0x7f, j: 0x7e, f: 0x7d, d: 0x7c};
      if ((result !== 'v' && !valueTypes[result]) || arguments_.some(x => !valueTypes[x])) {
        throw new Error('Unsupported Objective-C adapter ABI: ' + signature);
      }
      var functionType = [0x60, ...this.vector(arguments_.map(x => [valueTypes[x]])),
                          ...this.vector(result === 'v' ? [] : [[valueTypes[result]]])];
      var invokeType = [0x60, 3, 0x7f, 0x7f, 0x7f, 0];
      var tlsType = [0x60, 0, 1, 0x7f];
      var imports = [];
      var import_ = (name, kind, type) => [...this.string('env'), ...this.string(name), kind, ...type];
      if (!block) imports.push(import_('objc4_forward', 0, [0]));
      imports.push(import_('memory', 2,
#if PTHREADS
        [3, 0, ...this.unsigned(65536)]
#else
        [0, 0]
#endif
      ));
      imports.push(import_('__indirect_function_table', 1, [0x70, 0, 0]));
      imports.push(import_('__memory_base', 3, [0x7f, 0]));
      imports.push(import_('__table_base', 3, [0x7f, 0]));
      var bodies = [];
      var adapter = [0]; // No locals.
      var receiver = Number(flags) & 1 ? 1 : 0;
      var localGet = index => [0x20, ...this.unsigned(index)];
      var bindingLoad = () => [0x23, 0,
#if PTHREADS
        0xfe, 0x10, 2, 0 // i32.atomic.load, acquire the published Block pointer
#else
        0x28, 2, 0
#endif
      ];
      if (block) {
        if (arguments_[receiver] !== 'p' || arguments_[receiver + 1] !== 'p') {
          throw new Error('A Block IMP must take an object receiver first');
        }
        if (receiver) adapter.push(...localGet(0)); // sret pointer
        adapter.push(...bindingLoad()); // Block instead of method receiver
        adapter.push(...localGet(receiver)); // Receiver instead of selector
        for (var i = receiver + 2; i < arguments_.length; ++i) {
          adapter.push(...localGet(i));
        }
        adapter.push(...bindingLoad(), 0x28, 2, 12); // Block_layout.invoke
        adapter.push(0x13, 0, 0, 0x0b); // return_call_indirect, type 0, table 0
      } else {
        for (var i = 0; i < arguments_.length; ++i) adapter.push(...localGet(i));
        adapter.push(0x12, 0, 0x0b); // return_call the typed forwarding import
      }
      bodies.push([...this.unsigned(adapter.length), ...adapter]);
      var loads = {p: [0x28, 2], i: [0x28, 2], j: [0x29, 3], f: [0x2a, 2], d: [0x2b, 3]};
      var stores = {p: [0x36, 2], i: [0x36, 2], j: [0x37, 3], f: [0x38, 2], d: [0x39, 3]};
      if (!block) {
        // void invoke(slot_array, result_slot, IMP): the complete original ABI.
        var invoke = [0];
        if (result !== 'v') invoke.push(...localGet(1));
        for (var i = 0; i < arguments_.length; ++i) {
          invoke.push(...localGet(0), ...loads[arguments_[i]], ...this.unsigned(i * 8));
        }
        invoke.push(...localGet(2), 0x11, 0, 0);
        if (result !== 'v') invoke.push(...stores[result], 0);
        invoke.push(0x0b);
        bodies.push([...this.unsigned(invoke.length), ...invoke]);
      }
      // The pthread dynamic linker calls this for every module, even when the
      // module has no TLS exports. Zero denotes an empty TLS allocation.
      bodies.push([4, 0, 0x41, 0, 0x0b]);
      var count = block ? 1 : 2;
      var firstFunction = block ? 0 : 1;
      var exports_ = [
        [...this.string('objc_adapter'), 0, firstFunction],
        [...this.string('objc_context'), 3, 2],
        [...this.string('_emscripten_tls_init'), 0, block ? 1 : 3]
      ];
      if (!block) exports_.push([...this.string('objc_invoke'), 0, 2]);
      var elements = [1, 0, 0x23, 1, 0x0b, count, firstFunction];
      if (!block) elements.push(2);
      var memoryInfo = [4, 2, count, 0]; // 4-byte binding cell, alignment 4
      var dylink = [...this.string('dylink.0'), 1, memoryInfo.length, ...memoryInfo];
      var bytes = new Uint8Array([
        0, 0x61, 0x73, 0x6d, 1, 0, 0, 0,
        ...this.section(0, dylink),
        ...this.section(1, this.vector(block ? [functionType, tlsType] : [functionType, invokeType, tlsType])),
        ...this.section(2, this.vector(imports)),
        ...this.section(3, this.vector(block ? [[0], [1]] : [[0], [1], [2]])),
        ...this.section(6, [1, 0x7f, 0, 0x41, 0, 0x0b]),
        ...this.section(7, this.vector(exports_)),
        ...this.section(9, elements),
        ...this.section(10, this.vector(bodies))
      ]);
      var template = {bytes, module: new WebAssembly.Module(bytes), arguments_, result};
      this.templates.set(key, template);
      return template;
    },

    forward(template, cell, args) {
      var saved = stackSave();
      try {
        var frame = stackAlloc((args.length + 1) * 8);
        var result = frame + args.length * 8;
        HEAPU32[result >> 2] = 0;
        HEAPU32[(result + 4) >> 2] = 0;
        for (var i = 0; i < args.length; ++i) {
          var offset = frame + i * 8;
          switch (template.arguments_[i]) {
            case 'p': case 'i':
              HEAPU32[offset >> 2] = args[i]; HEAPU32[(offset + 4) >> 2] = 0; break;
            case 'j': HEAP64[offset >> 3] = args[i]; break;
            case 'f': HEAPF32[offset >> 2] = args[i]; break;
            case 'd': HEAPF64[offset >> 3] = args[i]; break;
          }
        }
#if PTHREADS
        var context = Atomics.load(HEAPU32, cell >> 2);
#else
        var context = HEAPU32[cell >> 2];
#endif
        _objc_wasm_forward_invoke(context, frame, result);
        switch (template.result) {
          case 'p': case 'i': return HEAPU32[result >> 2];
          case 'j': return HEAP64[result >> 3];
          case 'f': return HEAPF32[result >> 2];
          case 'd': return HEAPF64[result >> 3];
        }
      } finally {
        stackRestore(saved);
      }
    },

    install() {
      var load = loadWebAssemblyModule;
      loadWebAssemblyModule = (binary, flags, name, scope, handle) => {
        if (!name || !name.startsWith('/__objc4_adapter_')) {
          return load(binary, flags, name, scope, handle);
        }
        var match = name.match(/_([bf])_(.+)\.wasm$/);
        var block = match[1] === 'b';
        var template = objc4Adapters.create(match[2], block);
        var cell;
        var local = Object.assign({}, scope);
        if (!block) local['objc4_forward'] = (...args) => objc4Adapters.forward(template, cell, args);
        var loaded = load(template.module, flags, name, local, handle);
        var finish = (exports) => {
          cell = Number(exports['objc_context'].value);
          return exports;
        };
        // Other Workers replay dlopen events asynchronously during dlsync.
        return flags.loadAsync ? loaded.then(finish) : finish(loaded);
      };
    }
  },

  objc_wasm_prepare_adapter__deps: ['$objc4Adapters'],
  objc_wasm_prepare_adapter__sig: 'iiii',
  objc_wasm_prepare_adapter__proxy: 'sync',
  objc_wasm_prepare_adapter: (path, signature, block) => {
    try {
      var template = objc4Adapters.create(UTF8ToString(signature), !!block);
      FS.writeFile(UTF8ToString(path), template.bytes);
      return 1;
    } catch (error) {
      err('objc4 adapter: ' + error);
      return 0;
    }
  },

  objc_wasm_discard_adapter_file__deps: ['$FS', '$UTF8ToString'],
  objc_wasm_discard_adapter_file__sig: 'vi',
  objc_wasm_discard_adapter_file__proxy: 'sync',
  objc_wasm_discard_adapter_file: (path) => FS.unlink(UTF8ToString(path))
});
