"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const filename = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const original = fs.readFileSync(filename, "utf8").replace(/\r\n/gu, "\n");
const source = original.replace("  return installWhenDocumentReady(api, state, install, probe);\n})();", "  globalThis.fixture = { state, collectModel, hostName, nativeConnectionStatus, startNativeConnectionObservation, refreshDeviceHealth, refreshNativeConnectionCatalog, refreshNativeConnectionSnapshot, publishedLocalProjectSnapshot, scheduleRemoteProjectInventory, hydrateNativeInventory, runDeviceRefresh, connectionGuidance, diagnosticSnapshot, uninstall };\n})();");
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
const localHost = "remote-control:" + "env" + "_local_fixture";
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
  first.f.state.remoteProjectInventories.set(localHost, { hostDisplayName: "Fixture Local", projects: [], tasks: new Map(), threads: [] });
  first.f.state.hostConnectivity.set(localHost, { available: false, checkedAt: Date.now() });
  first.snapshots.set("remote_control_connections_state", nativeState(true));
  first.snapshots.set("remote_control_connections", [
    { hostId: host, displayName: "Named workstation", hostName: "reported-hostname", online: true, autoConnect: true },
    { hostId: localHost, displayName: "Fixture Local.local", online: false, autoConnect: false },
  ]);
  [...first.intervals.values()][0]();
  assert.equal(first.f.nativeConnectionStatus(), "authorized");
  assert.equal(first.f.state.nativeConnectionSnapshot.connections.length, 1, "the native catalogue must exclude the current machine");
  assert.equal(first.f.state.localRuntimeHostIds.has(localHost), true, "the native local id must be remembered across every discovery path");
  assert.equal(first.f.state.remoteProjectInventories.has(localHost), false, "cached self inventory must be removed");
  assert.equal(first.f.state.hostConnectivity.has(localHost), false, "cached self connectivity must be removed");
  assert.equal(first.f.state.remoteRuntimeCache.size, 0, "authorization must discard obsolete runtime discovery");
  assert.equal(first.f.state.remoteRuntimeScannedAt, 0);
  assert.equal(first.f.state.nativeConnectionRefreshPending, true, "a restored connection must bypass the previous inventory retry delay");
  assert.equal(first.f.collectModel().hosts.some(item => item.id === localHost), false, "the current machine must not return as a disconnected remote duplicate");
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
  assert.equal(model.hosts.find(item => item.id === host).available, true);

  // Current direct Codex data must outrank an older helper snapshot. During a
  // staggered upgrade the helper can retain the task's previous project even
  // though the native catalog and thread/list already contain its new home.
  const priorRegisteredProjects = first.f.state.localRegisteredProjects;
  const priorRegisteredProjectsFetchedAt = first.f.state.localRegisteredProjectsFetchedAt;
  const priorThreadInventory = first.f.state.threadInventories.get(host);
  const priorHelperInventory = first.f.state.remoteProjectInventories.get(host);
  const movedId = "00000000-0000-4000-8000-000000000089";
  const orphanId = "00000000-0000-4000-8000-000000000090";
  const directProject = { cwd: "/fixture/new", hostDisplayName: "Named workstation", hostId: host, item: null, label: "New project", projectId: "project-new" };
  first.f.state.localRegisteredProjects = new Map([[directProject.projectId, directProject]]);
  first.f.state.localRegisteredProjectsFetchedAt = Date.now();
  first.f.state.threadInventories.set(host, {
    error: null, fetchedAt: Date.now(), hostId: host, pages: 1, retryAt: 0, truncated: false,
    threads: [
      { cwd: directProject.cwd, id: movedId, projectId: directProject.projectId, status: "idle", title: "Moved task" },
      { cwd: "/fixture/orphan", id: orphanId, projectId: null, status: "idle", title: "Orphan task" },
    ],
  });
  first.f.state.remoteProjectInventories.set(host, {
    error: "older helper publisher unavailable", fetchedAt: Date.now() - 600000, generatedAt: Date.now() - 600000,
    pending: true, projects: [{ cwd: "/fixture/old", name: "Old project", rootPaths: ["/fixture/old"] }], tasks: new Map(),
    threads: [{ cwd: "/fixture/old", id: movedId, projectId: "project-old", status: "idle", title: "Moved task" }], threadsAuthoritative: true,
  });
  const movedModel = first.f.collectModel();
  const movedTask = movedModel.tasks.find(task => task.conversationId === movedId);
  assert.equal(movedTask.cwd, directProject.cwd, "stale helper data must not replace a current direct task path");
  assert.equal(movedTask.projectId, directProject.projectId, "stale helper data must not replace a current direct task project id");
  assert.equal(movedTask.inventoryFresh, true, "stale helper data must not invalidate current direct task authority");
  assert.equal(movedModel.projects.some(project => project.cwd === "/fixture/old"), false, "stale helper projects must not filter or supplement a current direct catalog");
  assert.ok(movedModel.projects.some(project => project.cwd === directProject.cwd), "the current direct project must remain visible");
  assert.ok(movedModel.recents.some(group => group.tasks.some(task => task.conversationId === orphanId)), "an unmatched task from a complete direct catalog must remain in Recent chats");
  first.f.state.localRegisteredProjects = priorRegisteredProjects;
  first.f.state.localRegisteredProjectsFetchedAt = priorRegisteredProjectsFetchedAt;
  if (priorThreadInventory) first.f.state.threadInventories.set(host, priorThreadInventory); else first.f.state.threadInventories.delete(host);
  first.f.state.remoteProjectInventories.set(host, priorHelperInventory);

  // An ordinary inventory failure must keep the discovered runtime cached. A
  // known-offline peer otherwise turns every retry/render into another bounded
  // full React graph scan.
  const failingRequests = [];
  const failingRuntime = { requestClient: { sendRequest: async (method) => {
    failingRequests.push(method);
    throw Error("Codex app-server is not available");
  } } };
  const scanMarker = Date.now();
  first.f.state.remoteRuntimeCache.set(host, failingRuntime);
  first.f.state.remoteRuntimeScannedAt = scanMarker;
  await first.f.scheduleRemoteProjectInventory(new Map([[host, failingRuntime]]), true);
  assert.ok(failingRequests.length >= 1);
  assert.equal(first.f.state.remoteRuntimeCache.get(host), failingRuntime, "request failure must retain the runtime until discovery is explicitly invalidated");
  assert.equal(first.f.state.remoteRuntimeScannedAt, scanMarker, "request failure must not force another full runtime scan");
  assert.deepEqual([...first.f.collectModel().projects.map(project => project.name)].sort(), ["Empty alpha", "Empty beta"], "a read failure must retain cached project rows");
  assert.equal(first.f.collectModel().hosts.find(item => item.id === host).available, true, "a recent helper failure must not override an explicit native-online event");

  first.snapshots.set("remote_control_connections", [{ hostId: host, displayName: "Named workstation", online: false }]);
  [...first.intervals.values()][0]();
  const readsBeforeOfflineRefresh = reads.length;
  await first.f.scheduleRemoteProjectInventory(new Map([[host, runtime]]), true);
  assert.equal(reads.length, readsBeforeOfflineRefresh, "an explicitly offline peer must not receive an inventory request");
  first.f.state.remoteRuntimeCache.set(host, runtime);
  first.f.state.remoteRuntimeScannedAt = Date.now();
  first.f.state.threadInventories.set(host, { hostId: host, error: "old offline error", threads: [], retryAt: 0 });
  await first.f.hydrateNativeInventory(true, first.f.state.discoveryGeneration);
  assert.equal(reads.length, readsBeforeOfflineRefresh, "native thread hydration must also skip an explicitly offline peer");
  assert.equal(first.f.state.inventoryHydrationError, null, "an offline peer's retained error must not fail refresh aggregation");
  const offlineModel = first.f.collectModel();
  assert.equal(offlineModel.hosts.find(item => item.id === host).available, false, "native disconnect must win immediately over older helper evidence");
  assert.equal(first.f.connectionGuidance(offlineModel.hosts.find(item => item.id === host)).code, "disconnected");
  assert.deepEqual([...offlineModel.projects.map(project => project.name)].sort(), ["Empty alpha", "Empty beta"], "offline state must preserve last-known project rows");

  const offlineGeneration = first.f.state.discoveryGeneration;
  const offlineRuntime = first.f.state.remoteRuntimeCache.get(host);
  const allOfflineRefresh = await first.f.runDeviceRefresh(offlineGeneration);
  assert.equal(allOfflineRefresh.complete, true, "all known offline peers must be a complete refresh");
  assert.equal(allOfflineRefresh.error, null, "all known offline peers must not produce an actionable refresh error");

  first.snapshots.delete("remote_control_connections");
  [...first.intervals.values()][0]();
  assert.equal(first.f.state.discoveryGeneration, offlineGeneration, "a missing native catalog must not invalidate discovery");
  assert.equal(first.f.state.remoteRuntimeCache.get(host), offlineRuntime, "a missing native catalog must retain the offline runtime cache");
  assert.equal(first.f.collectModel().hosts.find(item => item.id === host).available, false, "a missing native catalog must preserve authoritative offline state");
  await first.f.scheduleRemoteProjectInventory(new Map([[host, runtime]]), true);
  assert.equal(reads.length, readsBeforeOfflineRefresh, "a missing native catalog must not reopen remote reads");

  first.snapshots.set("remote_control_connections", [{ hostId: host, displayName: "Named workstation", online: false }]);
  first.snapshots.delete("remote_control_connections_state");
  [...first.intervals.values()][0]();
  assert.equal(first.f.state.discoveryGeneration, offlineGeneration, "a missing native status must not invalidate discovery");
  assert.equal(first.f.state.remoteRuntimeCache.get(host), offlineRuntime, "a missing native status must retain the offline runtime cache");
  assert.equal(first.f.collectModel().hosts.find(item => item.id === host).available, false, "a missing native status must preserve authoritative offline state");
  await first.f.scheduleRemoteProjectInventory(new Map([[host, runtime]]), true);
  assert.equal(reads.length, readsBeforeOfflineRefresh, "a missing native status must not reopen remote reads");

  first.snapshots.set("remote_control_connections_state", nativeState(true));
  first.snapshots.set("remote_control_connections", [{ hostId: host, displayName: "Named workstation", online: true }]);
  [...first.intervals.values()][0]();
  assert.equal(first.f.state.nativeConnectionRefreshPending, true, "reconnect must request a retry that bypasses the previous error gate");
  await first.f.scheduleRemoteProjectInventory(new Map([[host, runtime]]), first.f.state.nativeConnectionRefreshPending);
  assert.equal(reads.length, readsBeforeOfflineRefresh + 2, "reconnect must perform a fresh home and inventory read");
  assert.equal(first.f.collectModel().hosts.find(item => item.id === host).available, true);

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

  const sameName = boot();
  sameName.bridge();
  sameName.snapshots.set("remote_control_connections_state", nativeState(true));
  sameName.snapshots.set("remote_control_connections", [{ hostId: host, displayName: "Fixture Local.local", online: true }]);
  sameName.f.startNativeConnectionObservation();
  assert.equal(sameName.f.state.nativeConnectionSnapshot.connections.length, 1, "an online distinct peer must not be removed solely because its editable name matches this computer");
  assert.equal(sameName.f.state.localRuntimeHostIds.has(host), false, "direct native proof must reverse an earlier ambiguous name-only classification");
  assert.equal(sameName.f.collectModel().hosts.find(item => item.id === host).name, "Fixture Local.local", "the same-named connected peer must remain visible");
  sameName.f.uninstall();

  const forced = boot();
  forced.bridge();
  forced.snapshots.set("remote_control_connections_state", nativeState(true));
  forced.snapshots.set("remote_control_connections", [{ hostId: host, displayName: "Named workstation", online: false }]);
  let forcedCatalogueRefreshes = 0;
  forced.f.state.localFetchFromHost = async action => {
    assert.equal(action, "refresh-remote-control-connections");
    forcedCatalogueRefreshes += 1;
    forced.snapshots.set("remote_control_connections", [{ hostId: host, displayName: "Named workstation", online: true }]);
    return { remoteControlConnections: [{ hostId: host, displayName: "Named workstation", online: true }] };
  };
  forced.f.state.healthRefreshUntil = 0;
  const forcedGeneration = forced.f.state.discoveryGeneration;
  assert.equal(forced.f.refreshDeviceHealth(), true, "an explicit refresh must start one coordinator cycle");
  const forcedPromise = forced.f.state.deviceRefreshPromise;
  await forcedPromise;
  await flush();
  assert.equal(forcedCatalogueRefreshes, 1, "one refresh click must perform one forced native catalogue round trip");
  assert.equal(forced.f.state.discoveryGeneration, forcedGeneration + 1, "the coordinator-owned catalogue update must not supersede its active generation");
  assert.equal(forced.f.state.deviceRefreshQueued, false, "the coordinator-owned catalogue update must not queue a second refresh");
  assert.equal(forced.f.state.deviceRefreshPending, false, "the forced discovery pass must settle after the one backend round trip");
  forced.f.uninstall();

  const automatic = boot();
  automatic.bridge();
  automatic.snapshots.set("remote_control_connections_state", nativeState(true));
  automatic.snapshots.set("remote_control_connections", [{ hostId: host, displayName: "Named workstation", online: false }]);
  let catalogueRefreshes = 0;
  automatic.f.state.localFetchFromHost = async action => {
    assert.equal(action, "refresh-remote-control-connections");
    catalogueRefreshes += 1;
    automatic.snapshots.set("remote_control_connections", [{ hostId: host, displayName: "Named workstation", online: true }]);
    return { remoteControlConnections: [{ hostId: host, displayName: "Named workstation", online: true }] };
  };
  automatic.context.document.visibilityState = "hidden";
  automatic.f.startNativeConnectionObservation();
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(catalogueRefreshes, 0, "a hidden renderer must not poll the account connection catalogue");
  [...automatic.intervals.values()][0]();
  await flush();
  assert.equal(catalogueRefreshes, 0, "background observation must stay local while the renderer is hidden");
  automatic.context.document.visibilityState = "visible";
  [...automatic.intervals.values()][0]();
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(catalogueRefreshes, 1, "visible observation must refresh the native catalogue without opening Settings");
  assert.equal(automatic.f.collectModel().hosts.find(item => item.id === host).available, true, "automatic catalogue refresh must recover an old offline record");
  [...automatic.intervals.values()][0]();
  await flush();
  assert.equal(catalogueRefreshes, 1, "the two-second observer must honor the bounded native refresh cadence");
  automatic.f.uninstall();
  assert.deepEqual([...first.requests, ...second.requests], [], "observation must never initiate authorization or native connection mutations");
  console.log(JSON.stringify({ delayedNativeBridge: true, authorizationReported: true, catalogNamesWithoutRows: true, localCatalogEntryExcluded: true, sameNamedConnectedPeerRetained: true, forcedCatalogueSingleflight: true, forcedGenerationSettled: true, reconnectInvalidatesDiscovery: true, automaticNativeCatalogRefresh: true, backgroundCatalogPollingSuppressed: true, boundedNativeCatalogRefresh: true, emptyProjectTransportAndModel: true, offlineRequestsSuppressed: true, offlineNativeHydrationSuppressed: true, missingCatalogPreservesOffline: true, missingStatusPreservesOffline: true, allOfflineRefreshComplete: true, cachedRowsRetainedOffline: true, runtimeCacheRetainedOnFailure: true, nativeAvailabilityWins: true, reconnectForcesInventory: true, fullRendererRestartRetainsNames: true, renamedLabelsWinOverInventory: true, observerDisposed: true, noNativeMutations: true }));
})().catch(error => { console.error(error); process.exitCode = 1; });
