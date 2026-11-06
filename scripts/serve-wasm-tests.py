#!/usr/bin/env python3
"""Serve the built browser test matrix with the headers required by pthreads."""

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8127)
    parser.add_argument("--build-root", type=Path, default=Path(__file__).resolve().parent.parent / "build")
    options = parser.parse_args()
    build = options.build_root.resolve()
    report = build / "wasm-browser"
    report.mkdir(parents=True, exist_ok=True)
    configurations = [
        "wasm-single-Debug" if (build / "wasm-single-Debug").exists() else "wasm-Debug",
        "wasm-single-Release", "wasm-threads-Debug", "wasm-threads-Release"
    ]
    tests = []
    for configuration in configurations:
        directory = build / configuration
        for test in sorted(directory.glob("objc4-wasm-*.html")):
            tests.append({"name": configuration + "/" + test.stem,
                          "url": "/" + str(test.relative_to(build))})
    if not tests:
        parser.error("No browser test pages found; build the Wasm tests first")
    template = """<!doctype html><meta charset="utf-8"><title>objc4 Wasm validation</title>
<h1 id="status">Running browser tests</h1><p id="host"></p><ol id="results"></ol>
<iframe id="runner" title="Current runtime test" style="width:100%;height:250px"></iframe>
<script>
const tests = TESTS, results = [];
const host = {userAgent: navigator.userAgent, crossOriginIsolated};
document.getElementById('host').textContent = host.userAgent + '; crossOriginIsolated=' + crossOriginIsolated;
let current = 0, timeout;
const frame = document.getElementById('runner');
for (const test of tests) {
  const item = document.createElement('li'); item.textContent = 'WAIT: ' + test.name;
  document.getElementById('results').append(item);
}
function complete(code, error) {
  clearTimeout(timeout);
  results.push({name:tests[current].name, code, error});
  document.getElementById('results').children[current].textContent =
    (code === 0 ? 'PASS: ' : 'FAIL: ') + tests[current].name + (error ? ': ' + error : '');
  current++;
  next();
}
function next() {
  if (current === tests.length) {
    const passed = results.filter(x => x.code === 0).length;
    document.getElementById('status').textContent = `${passed}/${tests.length} browser tests passed`;
    fetch('/__results', {method:'POST', headers:{'Content-Type':'application/json'},
      body:JSON.stringify({host, results})});
    return;
  }
  frame.src = tests[current].url;
  timeout = setTimeout(() => complete(1, 'Test timed out'), 30000);
}
window.addEventListener('message', event => {
  if (event.origin === location.origin && event.source === frame.contentWindow &&
      event.data.objc4Test) complete(event.data.code, event.data.error);
});
next();
</script>"""
    (report / "index.html").write_text(template.replace("TESTS", json.dumps(tests)))

    class Handler(SimpleHTTPRequestHandler):
        def end_headers(self):
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.send_header("Cache-Control", "no-store")
            super().end_headers()

        def do_POST(self):
            if self.path != "/__results":
                self.send_error(404)
                return
            size = int(self.headers.get("Content-Length", "0"))
            if size > 65536:
                self.send_error(413)
                return
            result = json.loads(self.rfile.read(size))
            (report / "results.json").write_text(json.dumps(result, indent=2) + "\n")
            self.send_response(204)
            self.end_headers()

    server = ThreadingHTTPServer(("127.0.0.1", options.port), partial(Handler, directory=str(build)))
    print(f"Open http://127.0.0.1:{options.port}/wasm-browser/index.html ({len(tests)} tests)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
