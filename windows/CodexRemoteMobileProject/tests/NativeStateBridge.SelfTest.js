"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const original = fs.readFileSync(rendererPath, "utf8").replace(/\r\n/gu, "\n");
const source = original.replace("  return install();\n})();", "  globalThis.fixture = { state, ensureLocalStateBridge, nativeStateClientClass, nativeStateModuleUrls, saveDiagnosticPreview, previewAutoArchive, cleanupFailureReason, readCleanupHistory, recordCleanupEvent };\n})();");
assert.notEqual(source, original);
function fixture() {
  const storage = new Map();
  const context = vm.createContext({
    console, URL, AbortController, TextEncoder, TextDecoder, btoa, atob,
    setTimeout, clearTimeout, setInterval, clearInterval,
    requestAnimationFrame: () => 1, cancelAnimationFrame() {},
    crypto: { randomUUID: () => "native-bridge-fixture" }, navigator: {},
    location: { protocol: "app:", host: "-" },
    electronBridge: { sendMessageFromView: async () => {} },
    document: { querySelectorAll: selector => selector.startsWith("link") ? [
      { href: "https://untrusted.invalid/assets/app-initial-remote.js" },
      { href: "app://other/assets/app-initial-other.js" },
      { href: "app://-/assets/app-initial-fixture.js" },
    ] : [], getElementById: () => null },
    localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) },
  });
  vm.runInContext(source, context, { filename: rendererPath });
  return { context, f: context.fixture, storage };
}
(async () => {
  const { context, f, storage } = fixture();
  assert.deepEqual([...f.nativeStateModuleUrls()], ["app://-/assets/app-initial-fixture.js"]);
  const requests = [];
  let imports = 0, releaseImport;
  const importGate = new Promise(resolve => { releaseImport = resolve; });
  const fakeProxy = new Proxy(function () {}, { get: () => function () { throw Error("must not invoke an RPC proxy"); } });
  class NativeClient {
    static getInstance() { return NativeClient.instance; }
    onFetchResponse() {}
    async post(url, body, headers, signal) {
      requests.push({ url, body: JSON.parse(body) });
      assert.ok(signal instanceof AbortSignal);
      return { status: 200, body: { value: [] } };
    }
  }
  NativeClient.instance = new NativeClient();
  assert.equal(f.nativeStateClientClass(fakeProxy), false, "RPC proxies must not match native client descriptors");
  const load = async url => { imports++; assert.equal(url, "app://-/assets/app-initial-fixture.js"); await importGate; return { unknownProxy: fakeProxy, renamedExport: NativeClient }; };
  const first = f.ensureLocalStateBridge(load);
  assert.equal(f.ensureLocalStateBridge(load), first, "discovery must be singleflight");
  releaseImport();
  const bridge = await first;
  assert.equal(imports, 1);
  assert.equal(typeof bridge, "function");
  assert.deepEqual(requests, [{ url: "vscode://codex/get-global-state", body: { key: "pinned-thread-ids" } }]);
  await assert.rejects(bridge("run-arbitrary-command", { params: {} }), /Unsupported/);
  assert.equal(requests.length, 1, "unsupported actions must never reach the native service");

  f.state.localRuntime = { requestClient: { sendRequest: async method => { assert.equal(method, "thread/list"); return { data: [], nextCursor: null }; } } };
  const preview = await f.previewAutoArchive();
  assert.equal(preview.archiveEligible, 0);
  assert.equal(preview.deleteEligible, 0);
  assert.ok(requests.every(request => request.url.endsWith("get-global-state")), "recovered preview must remain read-only");
  assert.equal(storage.size, 0);

  f.state.diagnosticPreview = JSON.stringify({ unicode: "caf\u00e9 \ud83d\udd27", schemaVersion: 1 });
  let saves = 0, resolveSave;
  const saveGate = new Promise(resolve => { resolveSave = resolve; });
  f.state.localFetchFromHost = async (action, options) => {
    assert.equal(action, "save-file"); saves++;
    assert.equal(options.params.kind, "contents");
    assert.equal(Buffer.from(options.params.contentsBase64, "base64").toString("utf8"), f.state.diagnosticPreview);
    return saveGate;
  };
  const pending = f.saveDiagnosticPreview();
  assert.equal(f.state.diagnosticSavePending, true);
  assert.equal(await f.saveDiagnosticPreview(), false, "double clicks must not open two dialogs");
  resolveSave({ path: "C:\\chosen\\diagnostics.json" });
  assert.equal(await pending, true);
  assert.equal(saves, 1);
  assert.match(f.state.diagnosticFeedback, /JSON saved to C:/);
  assert.equal(f.state.diagnosticSavePending, false);
  f.state.localFetchFromHost = async () => ({ path: null });
  assert.equal(await f.saveDiagnosticPreview(), false);
  assert.equal(f.state.diagnosticFeedback, "Save cancelled. No file was saved.");
  f.state.localFetchFromHost = async () => ({ unexpected: true });
  assert.equal(await f.saveDiagnosticPreview(), false);
  assert.match(f.state.diagnosticFeedback, /could not be saved/);
  f.state.localFetchFromHost = async () => { throw Error("private path or credential must not appear in feedback"); };
  assert.equal(await f.saveDiagnosticPreview(), false);
  assert.doesNotMatch(f.state.diagnosticFeedback, /credential|private path/);

  delete context.electronBridge;
  let written, closed = false;
  context.showSaveFilePicker = async options => { assert.equal(options.suggestedName, "remote-enabler-diagnostics.json"); return { name: "diagnostics.json", createWritable: async () => ({ write: async text => { written = text; }, close: async () => { closed = true; } }) }; };
  assert.equal(await f.saveDiagnosticPreview(), true);
  assert.equal(written, f.state.diagnosticPreview);
  assert.equal(closed, true);
  context.showSaveFilePicker = async () => { const error = Error("cancel"); error.name = "AbortError"; throw error; };
  assert.equal(await f.saveDiagnosticPreview(), false);
  assert.match(f.state.diagnosticFeedback, /cancelled/);
  delete context.showSaveFilePicker;
  assert.equal(await f.saveDiagnosticPreview(), false);
  assert.match(f.state.diagnosticFeedback, /Copy preview/);
  assert.equal(f.cleanupFailureReason(Error("Local project-state bridge is unavailable")), "state-bridge");
  assert.equal(f.cleanupFailureReason(Error("Pinned task information is unavailable")), "pins");
  f.recordCleanupEvent("incomplete", null, Error("Pinned state missing: private/path"));
  assert.equal(f.readCleanupHistory()[0].reason, "pins");
  assert.doesNotMatch([...storage.values()].join(""), /private\/path/);

  const disposed = fixture();
  let releaseDisposed;
  const blocked = disposed.f.ensureLocalStateBridge(async () => { await new Promise(resolve => { releaseDisposed = resolve; }); return { NativeClient }; });
  disposed.f.state.disposed = true; releaseDisposed();
  assert.equal(await blocked, null);
  assert.equal(disposed.f.state.localFetchFromHost, null);
  f.state.disposed = true;
  console.log(JSON.stringify({ nativeBridgeDiscovery: true, proxyDescriptorsExcluded: true, sameAppModulesOnly: true, singleflightDiscovery: true, recoveredPreviewReadOnly: true, exactUnicodeSave: true, singleDialog: true, cancelAndFailureFeedback: true, browserPickerFallback: true, cleanupReasonsAllowlisted: true, disposedDiscoveryIgnored: true }));
})().catch(error => { console.error(error); process.exitCode = 1; });
