"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const filename = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const original = fs.readFileSync(filename, "utf8").replace(/\r\n/gu, "\n");
const source = original.replace("  return install();\n})();", "  globalThis.fixture = { state, collectModel, hostName, nativeConnectionStatus, startNativeConnectionObservation, refreshNativeConnectionSnapshot, publishedLocalProjectSnapshot, scheduleRemoteProjectInventory, connectionGuidance, diagnosticSnapshot, uninstall };\n})();");
assert.notEqual(source, original);
assert.match(original, /state\.disposed = false;\s+startNativeConnectionObservation\(\);/u, "normal installation must start observation");

function boot(storage = new Map()) {
  const intervals = new Map();
  let nextTimer = 0;
  const snapshots = new Map();
  const requests = [];
  const context = vm.createContext({
    console, URL, TextEncoder, TextDecoder, atob, btoa, AbortController,
    crypto: { randomUUID: () => "connection-fixture" },
    setTimeout, clearTimeout, requestAnimationFrame: () => 1, cancelAnimationFrame() {},
    setInterval: fn => { const id = ++nextTimer; intervals.set(id, fn); return id; },
    clearInterval: id => intervals.delete(id),
    Element: class {}, Node: class {}, CSS: { escape: String },
    document: { querySelectorAll: () => [], querySelector: () => null, getElementById: () => null, addEventListener() {}, removeEventListener() {} },
    localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) },
    __CODEX_REMOTE_MOBILE_CONFIG__: { localDisplayName: "Fixture local" },
  });
  vm.runInContext(source, context, { filename });
  const bridge = () => {
    context.electronBridge = {
      getSharedObjectSnapshotValue: key => snapshots.get(key),
      sendMessageFromView: message => { requests.push(message); throw Error("Connection observation must not send native actions"); },
    };
  };
  return { f: context.fixture, context, snapshots, storage, intervals, requests, bridge };
}
const host = "remote-control:" + "env" + "_lifecycle_peer";
const newHost = "remote-control:" + "env" + "_empty_peer";
const nativeState = (authorized, extra = {}) => ({ available: true, authRequired: false, accessRequired: false, clientAuthorized: authorized, ...extra });
const flush = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };

(async () => {
  const first = boot();
  first.f.startNativeConnectionObservation();
  first.f.startNativeConnectionObservation();
  assert.equal(first.intervals.size, 1, "normal installation must not add duplicate observers");
  assert.equal(first.f.nativeConnectionStatus(), "unknown", "an unavailable early bridge is not an authorization failure");
  first.bridge();
  first.snapshots.set("remote_control_connections_state", nativeState(false));
  first.snapshots.set("remote_control_connections", []);
  [...first.intervals.values()][0]();
  assert.equal(first.f.nativeConnectionStatus(), "authorization-required", "late native state must be noticed without sidebar mutations");
  assert.equal(first.f.connectionGuidance({ id: host }).code, "authorization-required");
  assert.match(first.f.connectionGuidance({ id: host }).next, /Settings > Connections/u);
  assert.equal(first.f.diagnosticSnapshot({ hosts: [], projects: [], tasks: [] }).nativeConnectionState, "authorization-required");
  assert.equal(first.f.refreshNativeConnectionSnapshot(), false, "unchanged polling must not trigger repeated work");

  first.f.state.remoteRuntimeCache.set(host, { obsolete: true });
  first.f.state.remoteRuntimeScannedAt = Date.now();
  first.snapshots.set("remote_control_connections_state", nativeState(true));
  first.snapshots.set("remote_control_connections", [{ hostId: host, displayName: "Named workstation", hostName: "reported-hostname", online: true, autoConnect: true }]);
  [...first.intervals.values()][0]();
  assert.equal(first.f.nativeConnectionStatus(), "authorized");
  assert.equal(first.f.state.remoteRuntimeCache.size, 0, "authorization must discard obsolete runtime discovery");
  assert.equal(first.f.state.remoteRuntimeScannedAt, 0);
  assert.equal(first.f.state.nativeConnectionRefreshPending, true, "a restored connection must bypass the previous inventory retry delay");
  assert.equal(first.f.collectModel().hosts.find(item => item.id === host).name, "Named workstation", "a device without sidebar rows must use the native label");
  assert.equal(first.f.collectModel().tasks.length, 0);
  assert.equal(first.f.collectModel().projects.length, 0);

  // Use the actual publisher snapshot and peer transport with no tasks and no
  // mounted local project rows. The folders must survive parsing and modeling.
  const published = first.f.publishedLocalProjectSnapshot({ value: {
    emptyOne: { id: "empty-one", name: "Empty alpha", rootPaths: ["/fixture/alpha"] },
    emptyTwo: { id: "empty-two", name: "Empty beta", rootPaths: ["/fixture/beta"] },
  } });
  assert.equal(published.available, true);
  assert.equal(published.projects.length, 2);
  const payload = {
    schemaVersion: 1, publisherVersion: 53, generatedAt: new Date().toISOString(), hostDisplayName: "reported-hostname",
    projects: published.projects, tasks: [], threads: [], threadScope: "user-visible", threadScopeGeneratedAt: new Date().toISOString(), peers: {},
  };
  const reads = [];
  const runtime = { requestClient: { sendRequest: async (method, params) => {
    reads.push(method);
    if (method === "config/read") return { home: "/fixture/.codex" };
    assert.equal(method, "fs/readFile");
    assert.match(params.path, /remote-project-inventory-v1\.json$/u);
    return { dataBase64: Buffer.from(JSON.stringify(payload)).toString("base64") };
  } } };
  first.f.state.remoteProjectInventories.set(host, { projects: [], tasks: new Map(), threads: [], error: "previous connection failed", retryAt: Date.now() + 60000 });
  first.f.scheduleRemoteProjectInventory(new Map([[host, runtime]]), first.f.state.nativeConnectionRefreshPending);
  await flush();
  assert.deepEqual(reads, ["config/read", "fs/readFile"]);
  const model = first.f.collectModel();
  assert.deepEqual([...model.projects.map(project => project.name)].sort(), ["Empty alpha", "Empty beta"]);
  assert.equal(model.tasks.length, 0);
  assert.equal(model.hosts.find(item => item.id === host).name, "Named workstation", "inventory hostnames must not replace a native device label");

  first.snapshots.set("remote_control_connections", []);
  first.snapshots.set("remote_control_connections_state", nativeState(false));
  [...first.intervals.values()][0]();
  assert.equal(first.f.hostName(host, new Map([[host, "Remote device"]]), null), "Named workstation");
  first.f.uninstall();
  assert.equal(first.intervals.size, 0, "uninstall must stop observation");
  assert.equal(first.f.refreshNativeConnectionSnapshot(), false);

  // A new VM context models a new renderer process: only durable storage is
  // retained. No previous globals, runtime clients, catalogs, or inventory.
  const second = boot(first.storage);
  second.bridge();
  second.snapshots.set("remote_control_connections", []);
  second.snapshots.set("remote_control_connections_state", nativeState(false));
  second.f.startNativeConnectionObservation();
  assert.equal(second.f.hostName(host, new Map([[host, "Remote device"]]), null), "Named workstation");
  assert.equal(second.f.hostName(newHost, new Map(), null), "Remote device", "an unknown peer must not inherit another peer's label");
  second.snapshots.set("remote_control_connections_state", nativeState(true));
  second.snapshots.set("remote_control_connections", [{ hostId: host, displayName: "Renamed workstation", online: true }, { envId: newHost.replace("remote-control:", ""), displayName: "Empty-project device", online: true }]);
  [...second.intervals.values()][0]();
  assert.equal(second.f.hostName(host, new Map(), null), "Renamed workstation");
  assert.equal(second.f.collectModel().hosts.find(item => item.id === newHost).name, "Empty-project device");
  second.snapshots.set("remote_control_connections_state", nativeState(false, { authRequired: true }));
  [...second.intervals.values()][0]();
  assert.equal(second.f.nativeConnectionStatus(), "sign-in-required");
  second.snapshots.set("remote_control_connections_state", nativeState(false, { accessRequired: true }));
  [...second.intervals.values()][0]();
  assert.equal(second.f.nativeConnectionStatus(), "access-required");
  second.snapshots.set("remote_control_connections_state", nativeState(false, { available: false }));
  [...second.intervals.values()][0]();
  assert.equal(second.f.nativeConnectionStatus(), "unavailable");
  second.f.uninstall();
  assert.deepEqual([...first.requests, ...second.requests], [], "observation must never initiate authorization or native connection mutations");
  console.log(JSON.stringify({ delayedNativeBridge: true, authorizationReported: true, catalogNamesWithoutRows: true, reconnectInvalidatesDiscovery: true, emptyProjectTransportAndModel: true, fullRendererRestartRetainsNames: true, renamedLabelsWinOverInventory: true, observerDisposed: true, noNativeMutations: true }));
})().catch(error => { console.error(error); process.exitCode = 1; });
