"use strict";

// This is a deterministic renderer fixture. It exercises the discovery and
// refresh coordinator with fake app-server clients; it never contacts Remote,
// an account, or a native registration service.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const originalSource = fs.readFileSync(rendererPath, "utf8").replace(/\r\n/gu, "\n");
const remoteHost = suffix => "remote-control:" + "env" + "_" + suffix;
const testSource = originalSource
  .replace("(() => {", "globalThis.__discoveryRefreshTest = (() => {")
  .replace("  return install();\n})();", `
  const realCollectModel = collectModel;
  const realDiscoverRemoteRuntimes = discoverRemoteRuntimes;
  const fixtureRuntimes = new Map();
  let fixtureFiber = null;
  let fixtureModel = { groups: [], hosts: [{ id: "local", name: "Fixture desktop", available: true, availabilityKnown: true }], projects: [], recents: [], remoteRuntimes: fixtureRuntimes, rows: [], tasks: [] };
  const navigationCalls = [];
  const recordNavigation = value => navigationCalls.push(value);
  // This deliberately matches the compact native dispatcher shape. A
  // discovery or refresh regression therefore becomes an observable call,
  // without requiring a native navigation implementation.
  const t = null;
  const navigation = e=>{recordNavigation(t,e)};
  const anchor = document.querySelector('[data-sidebar-project-kind="remote"][role="listitem"]')
    ?? document.querySelector('[data-sidebar-project-kind][role="listitem"]')
    ?? document.querySelector('[aria-label="Project sidebar options"]');
  if (anchor) {
    fixtureFiber = { memoizedState: null, return: null, updateQueue: { memoCache: { data: [null, [null, navigation]] } } };
    Object.defineProperty(anchor, "__reactFiber$fixture", { configurable: true, enumerable: true, value: fixtureFiber });
  }
  discoverHostNames = () => ({
    availability: new Map([...fixtureRuntimes.keys()].map(hostId => [hostId, true])),
    names: new Map(),
    registeredProjects: new Map(),
    runtimes: new Map(fixtureRuntimes),
  });
  collectModel = () => fixtureModel;
  render = () => { state.scheduledFrame = null; return { active: state.active, version: VERSION }; };
  globalThis.__discoveryRefreshFixture = {
    assignLocalRuntime,
    autoRegistrationCandidate,
    collectModel,
    realCollectModel,
    realDiscoverRemoteRuntimes,
    invalidateDiscoveryCaches,
    hydrateNativeInventory,
    navigationCalls,
    refreshDeviceHealth,
    requestDeviceRefresh: typeof requestDeviceRefresh === "function" ? requestDeviceRefresh : null,
    schedule,
    scheduleAutoRegistration,
    scheduleNativeInventoryHydration,
    scheduleRemoteProjectInventory,
    freshInventory,
    emptyInventoryMessage,
    inventoryContainsProject,
    projectIdentity,
    nativeNavigationDispatcher,
    readBoolean,
    remoteProjectDialog,
    uninstall,
    refreshLocalRegisteredProjects,
    scheduleLocalRegisteredProjectsRefresh,
    scheduleAutoReconciliation,
    setModel: value => { fixtureModel = value; },
    setRuntimes: entries => {
      fixtureRuntimes.clear();
      for (const [hostId, runtime] of entries ?? []) fixtureRuntimes.set(hostId, runtime);
      // Keep the fixture reachable through the same React fiber walk used by
      // production discovery. The fallback argument still covers callers that
      // have no mounted fiber, while this proves the cache observes a runtime
      // replacement discovered from the mounted app graph.
      if (fixtureFiber) fixtureFiber.memoizedState = [...fixtureRuntimes].map(([hostId, runtime]) => ({
        hostId,
        requestClient: runtime?.requestClient,
        fetchFromHost: runtime?.fetchFromHost,
      }));
    },
    state,
  };
})();`);
assert.notEqual(testSource, originalSource, "the renderer fixture must expose its real discovery entrypoints");

let nextTimerId;

class FixtureDate extends Date {
  static now() { return FixtureDate.clock; }
  constructor(...args) { super(...(args.length ? args : [FixtureDate.clock])); }
}
FixtureDate.clock = 1_800_000_000_000;

class FixtureElement {
  constructor(name = "fixture") {
    this.name = name;
    this.nodeType = 1;
    this.isConnected = true;
    this.style = { setProperty() {}, removeProperty() {} };
  }
  closest() { return null; }
  contains(candidate) { return candidate === this; }
  matches() { return false; }
  querySelector() { return null; }
  querySelectorAll() { return []; }
  getAttribute() { return null; }
}

function createHarness() {
  nextTimerId = 1;
  const timers = new Map();
  const options = new FixtureElement("options");
  const anchor = new FixtureElement("remote-project");
  const body = new FixtureElement("body");
  const head = new FixtureElement("head");
  const document = {
    body,
    head,
    addEventListener() {},
    removeEventListener() {},
    contains: element => Boolean(element?.isConnected),
    getElementById: () => null,
    querySelector(selector) {
      if (selector === '[aria-label="Project sidebar options"]') return options;
      if (selector.includes("data-sidebar-project-kind") || selector === "[data-app-action-sidebar-thread-row]") return anchor;
      return null;
    },
    querySelectorAll(selector) {
      if (selector === '[aria-label="Project sidebar options"]') return [options];
      return [];
    },
  };
  const storage = new Map();
  const context = vm.createContext({
    __CODEX_REMOTE_MOBILE_CONFIG__: { localDisplayName: "Fixture desktop" },
    CSS: { escape: value => String(value) },
    Date: FixtureDate,
    Element: FixtureElement,
    Node: FixtureElement,
    TextDecoder,
    TextEncoder,
    URL,
    AbortController,
    atob,
    btoa,
    cancelAnimationFrame: id => timers.delete(id),
    clearInterval: id => timers.delete(id),
    clearTimeout: id => timers.delete(id),
    console,
    document,
    globalThis: null,
    localStorage: {
      getItem: key => storage.get(key) ?? null,
      removeItem: key => storage.delete(key),
      setItem: (key, value) => storage.set(key, String(value)),
    },
    location: { href: "app://-/fixture" },
    MutationObserver: class { observe() {} disconnect() {} },
    navigator: { locks: { request: async (_name, _options, callback) => callback({}) } },
    queueMicrotask,
    requestAnimationFrame: callback => {
      const id = nextTimerId++;
      timers.set(id, { callback, due: FixtureDate.clock });
      return id;
    },
    setInterval: (callback, delay = 0) => {
      const id = nextTimerId++;
      timers.set(id, { callback, due: FixtureDate.clock + Math.max(0, Number(delay) || 0), interval: Math.max(1, Number(delay) || 1) });
      return id;
    },
    setTimeout: (callback, delay = 0, ...args) => {
      const id = nextTimerId++;
      timers.set(id, { args, callback, due: FixtureDate.clock + Math.max(0, Number(delay) || 0) });
      return id;
    },
  });
  context.globalThis = context;
  vm.runInContext(testSource, context, { filename: rendererPath });
  const fixture = context.__discoveryRefreshFixture;

  async function settle() {
    for (let index = 0; index < 80; index += 1) await Promise.resolve();
  }

  async function advanceTo(target) {
    for (;;) {
      const due = [...timers.entries()]
        .filter(([, timer]) => timer.due <= target)
        .sort((left, right) => left[1].due - right[1].due || left[0] - right[0])[0];
      if (!due) break;
      const [id, timer] = due;
      timers.delete(id);
      FixtureDate.clock = timer.due;
      timer.callback(...(timer.args ?? []));
      if (timer.interval) timers.set(id, { ...timer, due: timer.due + timer.interval });
      await settle();
    }
    FixtureDate.clock = target;
    await settle();
  }

  return { anchor, context, fixture, storage, timers, now: () => FixtureDate.clock, advanceTo, settle };
}

const id = suffix => `00000000-0000-4000-8000-000000000${suffix}`;

function inventory(now, hostId, name, cwd, threads = []) {
  return {
    error: null,
    fetchedAt: now,
    generatedAt: now,
    hostDisplayName: name,
    pending: false,
    projects: [{ cwd, name: `${name} project`, rootPaths: [cwd] }],
    projectsAuthoritative: true,
    publisherVersion: 53,
    retryAt: 0,
    tasks: new Map(),
    threadScope: "user-visible",
    threadScopeGeneratedAt: now,
    threads,
    threadsAuthoritative: true,
  };
}

function runtimeFor(harness, hostId, replies, calls) {
  return {
    requestClient: {
      async sendRequest(method, params) {
        calls.push({ hostId, method, params });
        const response = replies[method];
        if (typeof response === "function") return response(params);
        if (response instanceof Error) throw response;
        return response;
      },
    },
  };
}

async function expectRetainedAfterFailure(harness, hostId, message, response) {
  harness.fixture.setRuntimes([[hostId, runtimeFor(harness, hostId, { "thread/list": response }, [])]]);
  harness.fixture.state.remoteRuntimeCache.clear();
  harness.fixture.state.remoteRuntimeScannedAt = 0;
  harness.fixture.state.threadInventories.get(hostId).retryAt = 0;
  await harness.fixture.hydrateNativeInventory();
  await harness.settle();
  const retained = harness.fixture.state.threadInventories.get(hostId);
  assert.match(retained.error, new RegExp(message, "u"));
  assert.equal(retained.fetchedAt, harness.fixture.state.__priorFetchedAt, "failed inventory must retain the last successful timestamp");
  assert.equal(retained.threads.map(thread => thread.id).join("\u0000"), id("001"), "failed inventory must retain the valid rows already shown");
  assert.equal(retained.truncated, false, "an incomplete attempt must not discard a previously complete snapshot");
}

(async () => {
  // Automatic discovery must stay passive even when a v61 installation left
  // Auto-register enabled. A candidate is intentionally complete enough that
  // the legacy path would navigate to Add project after its 1.5s timer.
  {
    const h = createHarness();
    const hostId = remoteHost("quiet");
    const now = h.now();
    const project = { cwd: "/fixture/quiet", hostId, key: `${hostId}::cwd:/fixture/quiet`, kind: "project", name: "Quiet project", projectId: null, source: "host-projects", tasks: [{ conversationId: id("001"), hostId }] };
    h.storage.set("codex-remote-mobile-auto-register-enabled-v1", "true");
    h.fixture.state.localRegisteredProjectsFetchedAt = now;
    h.fixture.state.remoteProjectInventories.set(hostId, inventory(now, hostId, "Quiet peer", project.cwd));
    h.fixture.setModel({ groups: [project], hosts: [{ id: "local", name: "Fixture desktop", available: true, availabilityKnown: true }, { id: hostId, name: "Quiet peer", available: true, availabilityKnown: true }], projects: [project], recents: [], remoteRuntimes: new Map(), rows: [], tasks: project.tasks });
    h.fixture.scheduleAutoRegistration(h.fixture.collectModel());
    await h.advanceTo(now + 2000);
    assert.equal(h.fixture.navigationCalls.length, 0, "background discovery must never open native navigation or Add project");
    assert.equal(h.fixture.state.autoRegistrationPending, null, "quiet discovery must not leave a background registration in flight");

    // Reconnect, polling and an explicit refresh all use the same passive
    // discovery path. The legacy preference remains true throughout.
    h.fixture.scheduleAutoRegistration(h.fixture.collectModel());
    h.fixture.state.healthRefreshUntil = 0;
    h.fixture.refreshDeviceHealth();
    await h.advanceTo(h.now() + 2000);
    assert.equal(h.fixture.navigationCalls.length, 0, "reconnect and force refresh must remain navigation-free");
  }

  // Force refresh invalidates runtime and retry caches, reads both currently
  // discovered devices, and does not change the selected device filter.
  {
    const h = createHarness();
    const hosts = [remoteHost("alpha"), remoteHost("bravo")];
    const calls = [];
    const now = h.now();
    const runtimes = hosts.map((hostId, index) => {
      const cwd = `/fixture/${index ? "bravo" : "alpha"}`;
      const freshId = id(index ? "003" : "002");
      const payload = {
        generatedAt: new Date(now).toISOString(), hostDisplayName: index ? "Bravo peer" : "Alpha peer", projects: [{ name: "Fixture project", rootPaths: [cwd] }], publisherVersion: 53, schemaVersion: 1, tasks: [], threadScope: "user-visible", threadScopeGeneratedAt: new Date(now).toISOString(), threads: [{ cwd, id: freshId, projectId: `project-${index}`, status: "idle", title: `Fresh ${index}` }],
      };
      const runtime = runtimeFor(h, hostId, {
        "thread/list": { data: [{ cwd, id: freshId, projectId: `project-${index}`, status: "idle", title: `Fresh ${index}` }], nextCursor: null },
        "config/read": { codexHome: `C:\\Fixture\\${index}\\.codex` },
        "fs/readFile": { dataBase64: Buffer.from(JSON.stringify(payload)).toString("base64") },
      }, calls);
      h.fixture.state.threadInventories.set(hostId, { error: null, fetchedAt: now - 1000, hostId, pages: 1, retryAt: now + 60000, threads: [{ cwd, id: id("001"), projectId: `project-${index}`, status: "idle", title: "Old" }], truncated: false });
      h.fixture.state.remoteProjectInventories.set(hostId, inventory(now, index ? "Bravo peer" : "Alpha peer", hostId, cwd));
      return [hostId, runtime];
    });
    h.fixture.state.remoteRuntimeCache.set(hosts[0], { obsolete: true });
    h.fixture.state.remoteRuntimeCache.set(hosts[1], { obsolete: true });
    h.fixture.state.remoteRuntimeScannedAt = now;
    h.fixture.state.inventoryHydrationStarted = true;
    h.fixture.state.filter = hosts[1];
    const projectModel = { groups: [], hosts: [{ id: "local", name: "Fixture desktop", available: true, availabilityKnown: true }, ...hosts.map((hostId, index) => ({ id: hostId, name: index ? "Bravo peer" : "Alpha peer", available: true, availabilityKnown: true }))], projects: [], recents: [], remoteRuntimes: new Map(runtimes), rows: [], tasks: [] };
    h.fixture.setModel(projectModel);
    h.fixture.setRuntimes(runtimes);
    assert.equal(h.fixture.refreshDeviceHealth(), true, "the first explicit refresh must start a cycle");
    assert.equal(h.fixture.refreshDeviceHealth(), false, "repeated clicks must be coalesced");
    await h.advanceTo(now + 500);
    for (const hostId of hosts) {
      assert.equal(calls.filter(call => call.hostId === hostId && call.method === "thread/list").length, 1, `force refresh must bypass retry gates for ${hostId}`);
      assert.equal(h.fixture.state.threadInventories.get(hostId).threads[0].id, id(hostId === hosts[0] ? "002" : "003"));
    }
    assert.equal(h.fixture.state.remoteRuntimeCache.size, hosts.length, "force refresh must publish the current runtime handles");
    for (const [hostId, runtime] of runtimes) {
      assert.strictEqual(h.fixture.state.remoteRuntimeCache.get(hostId)?.requestClient, runtime.requestClient, "force refresh must replace stale runtime handles");
    }
    assert.ok(h.fixture.state.remoteRuntimeScannedAt >= now, "force refresh must record a fresh runtime scan");
    assert.equal(h.fixture.state.filter, hosts[1], "force refresh must preserve the selected device filter");
    assert.equal(h.fixture.navigationCalls.length, 0, "force refresh must never navigate to a project dialog");
  }

  // Runtime discovery itself is cache-aware: a replacement mounted in the
  // React graph remains hidden during the 30-second TTL, then becomes the sole
  // runtime used by a force refresh. This keeps the generation assertion tied
  // to production discoverRemoteRuntimes rather than a fixture override.
  {
    const h = createHarness();
    const hostId = remoteHost("runtime_cache");
    const now = h.now();
    const oldCalls = [];
    const newCalls = [];
    const oldRuntime = runtimeFor(h, hostId, { "thread/list": { data: [], nextCursor: null } }, oldCalls);
    const cwd = "/fixture/runtime-cache";
    const freshId = id("005");
    const payload = {
      generatedAt: new Date(now).toISOString(),
      hostDisplayName: "Replacement peer",
      projects: [{ name: "Fixture project", rootPaths: [cwd] }],
      publisherVersion: 53,
      schemaVersion: 1,
      tasks: [],
      threadScope: "user-visible",
      threadScopeGeneratedAt: new Date(now).toISOString(),
      threads: [{ cwd, id: freshId, projectId: "project-cache", status: "idle", title: "Fresh response" }],
    };
    const newRuntime = runtimeFor(h, hostId, {
      "thread/list": { data: [{ cwd, id: freshId, projectId: "project-cache", status: "idle", title: "Fresh response" }], nextCursor: null },
      "config/read": { codexHome: "C:\\Fixture\\runtime-cache\\.codex" },
      "fs/readFile": { dataBase64: Buffer.from(JSON.stringify(payload)).toString("base64") },
    }, newCalls);

    h.fixture.setRuntimes([[hostId, oldRuntime]]);
    const warmed = h.fixture.realDiscoverRemoteRuntimes(new Map([[hostId, oldRuntime]]));
    assert.strictEqual(warmed.get(hostId).requestClient, oldRuntime.requestClient, "the initial fiber discovery must cache the old runtime");
    const scansAfterWarm = h.fixture.state.counters.remoteRuntimeScans;

    h.fixture.setRuntimes([[hostId, newRuntime]]);
    const cached = h.fixture.realDiscoverRemoteRuntimes(new Map([[hostId, newRuntime]]));
    assert.strictEqual(cached.get(hostId).requestClient, oldRuntime.requestClient, "a runtime replacement must remain behind the live discovery TTL");
    assert.equal(h.fixture.state.counters.remoteRuntimeScans, scansAfterWarm, "a live TTL must avoid a second runtime graph walk");

    h.fixture.state.threadInventories.set(hostId, { error: null, fetchedAt: now - 1000, hostId, pages: 1, retryAt: now + 60000, threads: [{ id: id("001"), cwd, status: "idle", title: "Old" }], truncated: false });
    h.fixture.setModel({ groups: [], hosts: [{ id: "local", name: "Fixture desktop", available: true, availabilityKnown: true }, { id: hostId, name: "Replacement peer", available: true, availabilityKnown: true }], projects: [], recents: [], remoteRuntimes: new Map([[hostId, oldRuntime]]), rows: [], tasks: [] });
    assert.equal(h.fixture.refreshDeviceHealth(), true, "the force refresh must start after the cached replacement is installed");
    await h.advanceTo(now + 500);

    assert.equal(oldCalls.length, 0, "the superseded runtime must not receive a request after force invalidation");
    assert.equal(newCalls.filter(call => call.method === "thread/list").length, 1, "the replacement runtime must receive one fresh thread/list request");
    assert.strictEqual(h.fixture.state.remoteRuntimeCache.get(hostId).requestClient, newRuntime.requestClient, "force invalidation must publish the replacement runtime");
    assert.equal(h.fixture.state.counters.remoteRuntimeScans, scansAfterWarm + 1, "force invalidation must perform exactly one fresh runtime scan");
  }

  // Replacing a runtime under the same discovery generation must invalidate
  // both late outcomes of the old thread/list request. Seed the replacement
  // snapshot before releasing one old success and one old failure so either
  // stale completion is observable if the runtime identity guard is missing.
  {
    const h = createHarness();
    const hosts = [remoteHost("thread_replaced_success"), remoteHost("thread_replaced_failure")];
    const calls = [];
    let releaseSuccess;
    let rejectFailure;
    const oldSuccessRequest = new Promise(resolve => { releaseSuccess = resolve; });
    const oldFailureRequest = new Promise((_resolve, reject) => { rejectFailure = reject; });
    const oldRuntimes = [
      [hosts[0], runtimeFor(h, hosts[0], { "thread/list": () => oldSuccessRequest }, calls)],
      [hosts[1], runtimeFor(h, hosts[1], { "thread/list": () => oldFailureRequest }, calls)],
    ];
    const newRuntimes = hosts.map((hostId, index) => [hostId, runtimeFor(h, hostId, { "thread/list": { data: [{ cwd: "/fixture/thread-replacement", id: id(index ? "009" : "008"), status: "idle", title: "Replacement snapshot" }], nextCursor: null } }, calls)]);
    const now = h.now();
    for (const [index, hostId] of hosts.entries()) {
      h.fixture.state.threadInventories.set(hostId, { error: null, fetchedAt: now - 1000, hostId, pages: 1, retryAt: 0, threads: [{ cwd: "/fixture/thread-replacement", id: id("001"), status: "idle", title: "Prior snapshot" }], truncated: false });
    }
    h.fixture.setRuntimes(oldRuntimes);
    h.fixture.state.remoteRuntimeCache.clear();
    h.fixture.state.remoteRuntimeScannedAt = 0;
    h.fixture.state.inventoryHydrationStarted = false;
    const hydration = h.fixture.scheduleNativeInventoryHydration(true, h.fixture.state.discoveryGeneration);
    await h.settle();
    assert.equal(h.fixture.state.inventoryHydrationPending, true, "the old thread/list requests must remain pending");
    assert.equal(calls.filter(call => call.method === "thread/list").length, 2, "both old runtimes must be read before replacement");
    h.fixture.setRuntimes(newRuntimes);
    for (const [hostId, runtime] of newRuntimes) h.fixture.state.remoteRuntimeCache.set(hostId, runtime);
    for (const [index, hostId] of hosts.entries()) {
      h.fixture.state.threadInventories.set(hostId, { error: null, fetchedAt: h.now(), hostId, pages: 1, retryAt: 0, threads: [{ cwd: "/fixture/thread-replacement", id: id(index ? "009" : "008"), status: "idle", title: "Replacement snapshot" }], truncated: false });
    }
    releaseSuccess({ data: [{ cwd: "/fixture/thread-replacement", id: id("002"), status: "idle", title: "Late old success" }], nextCursor: null });
    rejectFailure(new Error("late old failure"));
    await hydration;
    await h.settle();
    assert.equal(h.fixture.state.threadInventories.get(hosts[0]).threads[0].id, id("008"), "a late old success must not replace the same-generation snapshot");
    assert.equal(h.fixture.state.threadInventories.get(hosts[0]).error, null);
    assert.equal(h.fixture.state.threadInventories.get(hosts[1]).threads[0].id, id("009"), "a late old failure must not replace the same-generation snapshot");
    assert.equal(h.fixture.state.threadInventories.get(hosts[1]).error, null);
  }

  // Force scheduling owns one waiter and one timer even when a dirty marker
  // arrives before the zero-delay timer fires. The force flag must survive the
  // reschedule and bypass a future retry gate exactly once.
  {
    const h = createHarness();
    const hostId = remoteHost("scheduler");
    const calls = [];
    const runtime = runtimeFor(h, hostId, { "thread/list": { data: [{ cwd: "/fixture/scheduler", id: id("006"), status: "idle", title: "Fresh scheduler row" }], nextCursor: null } }, calls);
    h.fixture.setRuntimes([[hostId, runtime]]);
    const now = h.now();
    h.fixture.state.threadInventories.set(hostId, { error: null, fetchedAt: now - 1000, hostId, pages: 1, retryAt: now + 60000, threads: [{ cwd: "/fixture/scheduler", id: id("001"), status: "idle", title: "Prior scheduler row" }], truncated: false });
    h.fixture.state.inventoryHydrationStarted = true;
    const forcePromise = h.fixture.scheduleNativeInventoryHydration(true);
    h.fixture.state.inventoryHydrationDirty = true;
    const dirtyPromise = h.fixture.scheduleNativeInventoryHydration(false);
    assert.strictEqual(dirtyPromise, forcePromise, "a dirty reschedule must preserve the force refresh waiter");
    await h.advanceTo(now);
    await forcePromise;
    assert.equal(calls.filter(call => call.method === "thread/list").length, 1, "a rescheduled force hydration must read membership once");
    assert.equal(h.fixture.state.threadInventories.get(hostId).threads[0].id, id("006"));
    assert.equal(h.fixture.state.threadInventories.get(hostId).retryAt, 0, "force hydration must bypass a future retry gate");

    const u = createHarness();
    const uninstallHost = remoteHost("scheduler_uninstall");
    const uninstallCalls = [];
    const uninstallRuntime = runtimeFor(u, uninstallHost, { "thread/list": { data: [], nextCursor: null } }, uninstallCalls);
    u.fixture.setRuntimes([[uninstallHost, uninstallRuntime]]);
    u.fixture.state.inventoryHydrationStarted = true;
    const abandoned = u.fixture.scheduleNativeInventoryHydration(true);
    u.fixture.uninstall();
    await abandoned;
    assert.equal(uninstallCalls.length, 0, "uninstall must settle an abandoned timer without issuing a request");
  }

  // A force refresh arriving behind an already-running background hydration
  // waits for that read, then performs one fresh generation. A replacement
  // runtime under the same host ID wins, while the old response cannot leave
  // the stale thread list on screen.
  {
    const h = createHarness();
    const hostId = remoteHost("replacement");
    const now = h.now();
    const calls = [];
    let releaseOld;
    const oldRuntime = runtimeFor(h, hostId, { "thread/list": () => new Promise(resolve => { releaseOld = () => resolve({ data: [{ id: id("001"), cwd: "/fixture/replaced", status: "idle", title: "Old response" }], nextCursor: null }); }) }, calls);
    const newRuntime = runtimeFor(h, hostId, { "thread/list": { data: [{ id: id("004"), cwd: "/fixture/replaced", status: "idle", title: "Fresh response" }], nextCursor: null } }, calls);
    h.fixture.state.threadInventories.set(hostId, { error: null, fetchedAt: now - 1000, hostId, pages: 1, retryAt: 0, threads: [{ id: id("000"), cwd: "/fixture/replaced", status: "idle", title: "Prior" }], truncated: false });
    h.fixture.setModel({ groups: [], hosts: [{ id: "local", name: "Fixture desktop", available: true, availabilityKnown: true }, { id: hostId, name: "Replacement peer", available: true, availabilityKnown: true }], projects: [], recents: [], remoteRuntimes: new Map([[hostId, oldRuntime]]), rows: [], tasks: [] });
    h.fixture.setRuntimes([[hostId, oldRuntime]]);
    h.fixture.state.inventoryHydrationStarted = false;
    const backgroundHydration = h.fixture.scheduleNativeInventoryHydration();
    await h.settle();
    assert.equal(h.fixture.state.inventoryHydrationPending, true, "the background hydration must remain pending while the old runtime response is unresolved");
    h.fixture.setRuntimes([[hostId, newRuntime]]);
    h.fixture.state.healthRefreshUntil = 0;
    assert.equal(h.fixture.refreshDeviceHealth(), true, "a force refresh must start behind the pending background hydration");
    await h.settle();
    assert.equal(h.fixture.state.deviceRefreshPending, true, "the force refresh must remain pending while the old runtime response is unresolved");
    releaseOld();
    await backgroundHydration;
    await h.settle();
    await h.advanceTo(h.now() + 500);
    assert.equal(calls.filter(call => call.method === "thread/list").length, 2, "the force refresh must perform one bounded follow-up read after the old background read settles");
    assert.equal(h.fixture.state.threadInventories.get(hostId).threads.map(thread => thread.id).join("\u0000"), id("004"), "the replacement runtime response must win over the old completion");
    assert.equal(h.fixture.state.deviceRefreshQueued, false);
    assert.equal(h.fixture.state.deviceRefreshPending, false);
  }

  // A reconnect force pass must not lose a remote fs/readFile that was already
  // pending. Once the stale read settles, the replacement runtime receives one
  // fresh inventory read and publishes that result.
  {
    const h = createHarness();
    const hostId = remoteHost("reconnect_inventory");
    const cwd = "/fixture/reconnect";
    const oldCalls = [];
    const newCalls = [];
    let releaseOld;
    const oldFile = new Promise(resolve => { releaseOld = resolve; });
    const now = h.now();
    const oldThread = { cwd, id: id("001"), status: "idle", title: "Old remote row" };
    const newThread = { cwd, id: id("010"), status: "idle", title: "Fresh remote row" };
    const oldRuntime = runtimeFor(h, hostId, {
      "config/read": { codexHome: "C:\\Fixture\\reconnect\\.codex" },
      "fs/readFile": () => oldFile,
    }, oldCalls);
    const newPayload = {
      generatedAt: new Date(now).toISOString(),
      hostDisplayName: "Fresh reconnect peer",
      projects: [{ cwd, name: "Reconnect project", rootPaths: [cwd] }],
      publisherVersion: 53,
      schemaVersion: 1,
      tasks: [],
      threadScope: "user-visible",
      threadScopeGeneratedAt: new Date(now).toISOString(),
      threads: [newThread],
    };
    const newRuntime = runtimeFor(h, hostId, {
      "thread/list": { data: [newThread], nextCursor: null },
      "config/read": { codexHome: "C:\\Fixture\\reconnect\\.codex" },
      "fs/readFile": { dataBase64: Buffer.from(JSON.stringify(newPayload)).toString("base64") },
    }, newCalls);
    h.fixture.state.remoteProjectInventories.set(hostId, inventory(now - 1000, hostId, "Old reconnect peer", cwd, [oldThread]));
    h.fixture.setRuntimes([[hostId, oldRuntime]]);
    h.fixture.state.remoteRuntimeCache.clear();
    h.fixture.state.remoteRuntimeScannedAt = 0;
    const oldInventoryRead = h.fixture.scheduleRemoteProjectInventory(new Map([[hostId, oldRuntime]]), true, h.fixture.state.discoveryGeneration);
    await h.settle();
    assert.equal(h.fixture.state.remoteProjectInventories.get(hostId).pending, true, "the old remote inventory read must be pending before reconnect");
    assert.equal(oldCalls.filter(call => call.method === "fs/readFile").length, 1);
    h.fixture.setRuntimes([[hostId, newRuntime]]);
    h.fixture.state.healthRefreshUntil = 0;
    assert.equal(h.fixture.refreshDeviceHealth(), true, "reconnect must start a force refresh");
    const refreshPromise = h.fixture.state.deviceRefreshPromise;
    await h.settle();
    releaseOld({ dataBase64: Buffer.from(JSON.stringify({ ...newPayload, hostDisplayName: "Late old peer", threads: [oldThread] })).toString("base64") });
    await oldInventoryRead;
    await refreshPromise;
    await h.settle();
    assert.equal(oldCalls.filter(call => call.method === "fs/readFile").length, 1, "the stale remote fs read must settle once");
    assert.equal(newCalls.filter(call => call.method === "fs/readFile").length, 1, "the reconnect force pass must reread remote inventory once");
    const current = h.fixture.state.remoteProjectInventories.get(hostId);
    assert.equal(current.hostDisplayName, "Fresh reconnect peer", "the replacement fs result must win over the stale completion");
    assert.equal(current.error, null);
    assert.equal(h.fixture.state.deviceRefreshPending, false);
  }

  // A forced local registered-project refresh bypasses its normal TTL. If a
  // stale-generation read is already pending, the force request queues behind
  // it and performs one current-generation reread after that old completion.
  {
    const h = createHarness();
    const hostId = remoteHost("local_registered");
    const calls = [];
    let releaseOld;
    const oldProject = { id: "registered-old", label: "Old registered project", hostId, remotePath: "/fixture/registered" };
    const forcedProject = { id: "registered-forced", label: "Forced registered project", hostId, remotePath: "/fixture/registered" };
    const oldPending = new Promise(resolve => { releaseOld = resolve; });
    h.fixture.state.localFetchFromHost = async (_action, options) => {
      calls.push(options?.params?.key);
      if (calls.length === 1) return { value: [forcedProject] };
      if (calls.length === 2) return oldPending;
      return { value: [oldProject] };
    };
    h.fixture.state.localRegisteredProjectsFetchedAt = h.now();
    const forced = h.fixture.scheduleLocalRegisteredProjectsRefresh(true, h.fixture.state.discoveryGeneration);
    await forced;
    assert.equal(calls.length, 1, "force must bypass the local registered-project TTL");
    assert.ok(h.fixture.state.localRegisteredProjects.has("registered-forced"));

    h.fixture.state.localRegisteredProjectsFetchedAt = 0;
    const staleGeneration = h.fixture.state.discoveryGeneration;
    const pendingRead = h.fixture.scheduleLocalRegisteredProjectsRefresh(false, staleGeneration);
    await h.settle();
    assert.equal(h.fixture.state.localRegisteredProjectsPending, true, "the old local registered-project read must remain pending");
    const currentGeneration = h.fixture.invalidateDiscoveryCaches();
    const queuedForce = h.fixture.scheduleLocalRegisteredProjectsRefresh(true, currentGeneration);
    assert.strictEqual(h.fixture.state.localRegisteredProjectsQueuedPromise, queuedForce, "a current force refresh must expose its queued waiter");
    releaseOld({ value: [oldProject] });
    await pendingRead;
    await queuedForce;
    await h.settle();
    assert.equal(calls.length, 3, "the stale pending read must be followed by one current-generation force read");
    assert.deepEqual(calls, ["remote-projects", "remote-projects", "remote-projects"]);
    assert.ok(h.fixture.state.localRegisteredProjects.has("registered-old"));
    assert.equal(h.fixture.state.localRegisteredProjects.has("registered-forced"), false, "the queued current read must replace the stale snapshot");
    assert.equal(h.fixture.state.localRegisteredProjectsPending, false);
    assert.equal(h.fixture.state.localRegisteredProjectsError, null);
  }

  // The legacy auto-registration preference must not re-enable automatic
  // reconciliation. Existing managed registrations remain untouched until an
  // explicit user removal path is invoked.
  {
    const h = createHarness();
    const hostId = remoteHost("legacy_managed");
    const project = { cwd: "/fixture/managed", hostId, key: `${hostId}::cwd:/fixture/managed`, kind: "project", name: "Managed project", projectId: "managed-project", source: "host-projects", tasks: [] };
    const managedRecord = JSON.stringify({ "managed-project": { cwd: project.cwd, hostId, projectId: project.projectId } });
    const bridgeCalls = [];
    h.storage.set("codex-remote-mobile-auto-register-enabled-v1", "true");
    h.storage.set("codex-remote-mobile-auto-managed-v1", managedRecord);
    h.fixture.state.localRegisteredProjects.set(project.projectId, { cwd: project.cwd, hostDisplayName: null, hostId, item: null, label: project.name, projectId: project.projectId });
    h.fixture.state.localFetchFromHost = async (...args) => { bridgeCalls.push(args); return { value: [] }; };
    const model = { groups: [project], hosts: [{ id: "local", name: "Fixture desktop", available: true, availabilityKnown: true }, { id: hostId, name: "Legacy device", available: true, availabilityKnown: true }], projects: [project], recents: [], remoteRuntimes: new Map(), rows: [], tasks: [] };
    h.fixture.setModel(model);
    h.fixture.scheduleAutoReconciliation(model);
    await h.advanceTo(h.now() + 2000);
    assert.equal(h.fixture.state.autoReconciliationPending, false);
    assert.ok(h.fixture.state.localRegisteredProjects.has(project.projectId), "a legacy managed registration must remain visible");
    assert.equal(h.storage.get("codex-remote-mobile-auto-managed-v1"), managedRecord, "legacy reconciliation must preserve managed-record state");
    assert.equal(bridgeCalls.length, 0, "retired automatic reconciliation must perform no native writes or reads");
  }

  // Failure, timeout, malformed pagination, and expiry retain the last valid
  // rows while the diagnostic state tells the truth about freshness.
  {
    const h = createHarness();
    const hostId = remoteHost("retained");
    const now = h.now();
    const oldThread = { id: id("001"), cwd: "/fixture/retained", status: "idle", title: "Retained chat" };
    const priorFetchedAt = now - 1000;
    h.fixture.state.__priorFetchedAt = priorFetchedAt;
    h.fixture.state.threadInventories.set(hostId, { error: null, fetchedAt: priorFetchedAt, hostId, pages: 1, retryAt: 0, threads: [oldThread], truncated: false });
    h.fixture.state.remoteProjectInventories.set(hostId, inventory(priorFetchedAt, hostId, "Retained peer", oldThread.cwd, [oldThread]));
    h.fixture.setModel({ groups: [], hosts: [{ id: "local", name: "Fixture desktop", available: true, availabilityKnown: true }, { id: hostId, name: "Retained peer", available: true, availabilityKnown: true }], projects: [], recents: [], remoteRuntimes: new Map(), rows: [], tasks: [] });

    await expectRetainedAfterFailure(h, hostId, "unavailable", new Error("device unavailable"));
    await expectRetainedAfterFailure(h, hostId, "timed out", new Error("request timed out"));
    await expectRetainedAfterFailure(h, hostId, "repeated pagination cursor", { data: [{ id: id("002"), cwd: oldThread.cwd, status: "idle" }], nextCursor: "same" });

    // An unavailable host remains represented after the three-minute
    // authority boundary, but its freshness is explicitly stale.
    FixtureDate.clock = now + 181000;
    h.fixture.setRuntimes([]);
    h.fixture.scheduleRemoteProjectInventory(new Map(), true);
    await h.settle();
    assert.ok(h.fixture.state.remoteProjectInventories.has(hostId), "expiry must retain the last inventory for a truthful stale row");
    h.fixture.state.displayedHosts = [{ id: "local", name: "Fixture desktop", available: true, availabilityKnown: true }, { id: hostId, name: "Retained peer", available: false, availabilityKnown: true }];
    const model = h.fixture.realCollectModel();
    assert.ok(model.tasks.some(task => task.conversationId === id("001")), "stale or unavailable refresh must keep the last valid chat row");
    assert.match(h.fixture.emptyInventoryMessage(hostId), /disconnected|out of date|stale/iu, "the retained row must expose truthful unavailable or stale freshness");
  }

  console.log(JSON.stringify({ quietDiscovery: true, noBackgroundNavigation: true, forceRefreshBypassesRetry: true, forceRefreshInvalidatesRuntimeCache: true, filterPreserved: true, pendingRerunBounded: true, replacementRuntimeWins: true, sameGenerationRuntimeReplacementWins: true, reconnectPendingInventoryReruns: true, localRegisteredForceQueuesBehindPending: true, retiredAutoReconciliationPreservesState: true, unavailableRowsRetained: true, timeoutRowsRetained: true, incompleteRowsRetained: true, staleRowsRetained: true, forceWaiterPreserved: true, forceReadOnce: true, uninstallSettlesScheduledWait: true }));
})().catch(error => { console.error(error); process.exitCode = 1; });
