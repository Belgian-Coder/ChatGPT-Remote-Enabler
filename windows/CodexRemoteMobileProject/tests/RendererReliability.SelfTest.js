"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { performance } = require("node:perf_hooks");

const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const originalSource = fs.readFileSync(rendererPath, "utf8").replace(/\r\n/gu, "\n");
const testSource = originalSource
  .replace("(() => {", "globalThis.__rendererReliabilityTest = (() => {")
  .replace("  return installWhenDocumentReady(api, state, install, probe);\n})();", `
  discoverHostNames = () => ({ availability: new Map(), names: new Map(), registeredProjects: new Map(), runtimes: new Map() });
  discoverRemoteRuntimes = () => new Map();
  render = () => {
    state.counters.renders += 1;
    state.scheduledFrame = null;
    scheduleNativeInventoryHydration();
    return { active: state.active, version: VERSION };
  };
  return { assignLocalRuntime, hydrateNativeInventory, installWhenDocumentReady, parseInventoryPayload, publishInventoryHeartbeat, readiness, schedule, scheduleLocalProjectInventoryPublication, scheduleNativeInventoryHydration, state, taskFromThread };
})();`);
assert.notEqual(testSource, originalSource, "full renderer test adapter must replace the production entrypoint");

let clock = 1_800_000_000_000;
let nextTimerId = 1;
const timers = new Map();
const animationFrames = new Map();

class FixtureDate extends Date {
  constructor(...args) { super(...(args.length ? args : [clock])); }
  static now() { return clock; }
}

class FixtureElement {
  constructor(props = null, attributes = {}) {
    this.nodeType = 1;
    this.attributes = attributes;
    if (props) this.__reactFiber$fixture = { memoizedProps: props, memoizedState: null, return: null, updateQueue: null };
  }
  closest() { return null; }
  contains(candidate) { return candidate === this || candidate?.insideFixturePanel === true; }
  getAttribute(name) { return this.attributes[name] ?? null; }
  hasAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attributes, name); }
  matches() { return false; }
  querySelector() { return null; }
}

function setFixtureTimeout(callback, delay = 0, ...args) {
  const id = nextTimerId++;
  timers.set(id, { args, callback, due: clock + Math.max(0, Number(delay) || 0) });
  return id;
}

function clearFixtureTimer(id) { timers.delete(id); }

function requestFixtureAnimationFrame(callback) {
  const id = nextTimerId++;
  animationFrames.set(id, callback);
  return id;
}

function flushAnimationFrames() {
  const pending = [...animationFrames.entries()];
  animationFrames.clear();
  for (const [, callback] of pending) callback(clock);
}

let nativeTasks = [];
const document = {
  addEventListener() {},
  getElementById: () => null,
  querySelector(selector) { return selector === '[aria-label="Project sidebar options"]' ? new FixtureElement() : null; },
  querySelectorAll: selector => selector === '[data-app-action-sidebar-thread-row]' ? nativeTasks : [],
  removeEventListener() {},
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
  atob,
  btoa,
  cancelAnimationFrame: id => animationFrames.delete(id),
  clearInterval: clearFixtureTimer,
  clearTimeout: clearFixtureTimer,
  console,
  crypto: { randomUUID: () => "renderer-reliability-fixture" },
  document,
  globalThis: null,
  localStorage: {
    getItem: key => storage.get(key) ?? null,
    removeItem: key => storage.delete(key),
    setItem: (key, value) => storage.set(key, String(value)),
  },
  navigator: { locks: { request: async (_name, _options, callback) => callback({}) } },
  performance,
  queueMicrotask,
  requestAnimationFrame: requestFixtureAnimationFrame,
  setInterval: setFixtureTimeout,
  setTimeout: setFixtureTimeout,
});
context.globalThis = context;
context.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__ = {
  version: 95,
  probe: () => ({ active: true, view: "native", filter: "local" }),
  uninstall() {},
};
vm.runInContext(testSource, context, { filename: rendererPath });
const reliability = context.__rendererReliabilityTest;
assert.equal(reliability.state.view, "native", "a live update preserves the chosen sidebar view");
assert.equal(reliability.state.filter, "local", "a live update preserves the chosen device filter");

async function drainAsyncWork() {
  for (let turn = 0; turn < 20; turn += 1) {
    await new Promise(resolve => setImmediate(resolve));
    flushAnimationFrames();
    if (!reliability.state.inventoryHydrationPending && !reliability.state.localInventoryPublisherPending && animationFrames.size === 0) return;
  }
  assert.fail("renderer background work did not settle");
}

async function advanceTo(target) {
  for (;;) {
    const due = [...timers.entries()]
      .filter(([, timer]) => timer.due <= target)
      .sort((left, right) => left[1].due - right[1].due || left[0] - right[0])[0];
    if (!due) break;
    const [id, timer] = due;
    timers.delete(id);
    clock = timer.due;
    timer.callback(...timer.args);
    await drainAsyncWork();
  }
  clock = target;
  await drainAsyncWork();
}

(async () => {
  const listeners = [];
  const loadingDocument = {
    body: null,
    addEventListener(name, listener, options) {
      assert.equal(name, "DOMContentLoaded");
      assert.equal(options?.once, true);
      listeners.push(listener);
    },
  };
  const rendererRoot = {};
  let oldInstalls = 0;
  const oldState = { active: false, disposed: false };
  const oldApi = {
    install() { oldInstalls += 1; oldState.active = true; return { active: true, version: 87 }; },
    probe() { return { active: oldState.active && !oldState.disposed, version: 87 }; },
  };
  rendererRoot.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__ = oldApi;
  const oldPending = reliability.installWhenDocumentReady(
    oldApi, oldState, oldApi.install, () => ({ active: oldState.active, version: 87 }),
    { document: loadingDocument, root: rendererRoot },
  );
  oldState.disposed = true;

  let currentInstalls = 0;
  const currentState = { active: false, disposed: false };
  const currentApi = {
    install() { currentInstalls += 1; currentState.active = true; return { active: true, version: 89 }; },
    probe() { return { active: currentState.active && !currentState.disposed, version: 89 }; },
  };
  rendererRoot.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__ = currentApi;
  const currentPending = reliability.installWhenDocumentReady(
    currentApi, currentState, currentApi.install, () => ({ active: currentState.active, version: 89 }),
    { document: loadingDocument, root: rendererRoot },
  );
  assert.equal(listeners.length, 2);
  loadingDocument.body = {};
  for (const listener of listeners) listener();
  const [oldResult, currentResult] = await Promise.all([oldPending, currentPending]);
  assert.equal(oldInstalls, 0, "the disposed pre-DOM renderer must not reactivate");
  assert.equal(currentInstalls, 1, "reinjection must install only the current renderer");
  assert.equal(oldState.disposed, true);
  assert.equal(oldResult.active, false, "the superseded evaluation must not activate another renderer owner");
  assert.equal(currentResult.active, true);

  const disposedListeners = [];
  const disposedDocument = {
    body: null,
    addEventListener(name, listener, options) {
      assert.equal(name, "DOMContentLoaded");
      assert.equal(options?.once, true);
      disposedListeners.push(listener);
    },
  };
  const disposedRoot = {};
  let disposedInstalls = 0;
  const supersededState = { active: false, disposed: true };
  const supersededApi = {
    install() { disposedInstalls += 1; return { active: true, version: 87 }; },
    probe() { return { active: false, version: 87 }; },
  };
  disposedRoot.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__ = supersededApi;
  const supersededPending = reliability.installWhenDocumentReady(
    supersededApi, supersededState, supersededApi.install, supersededApi.probe,
    { document: disposedDocument, root: disposedRoot },
  );
  const disposedCurrentState = { active: false, disposed: true };
  const disposedCurrentApi = {
    install() { disposedInstalls += 1; return { active: true, version: 89 }; },
    probe() { return { active: false, version: 89 }; },
  };
  disposedRoot.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__ = disposedCurrentApi;
  const disposedCurrentPending = reliability.installWhenDocumentReady(
    disposedCurrentApi, disposedCurrentState, disposedCurrentApi.install, disposedCurrentApi.probe,
    { document: disposedDocument, root: disposedRoot },
  );
  disposedDocument.body = {};
  for (const listener of disposedListeners) listener();
  const disposedResults = await Promise.all([supersededPending, disposedCurrentPending]);
  assert.equal(disposedInstalls, 0, "deferred callbacks must not reactivate a disposed current renderer");
  assert.deepEqual(disposedResults.map(result => result.active), [false, false]);

  let failThreadLists = false;
  let truncateThreadLists = false;
  let listCalls = 0;
  let writeCalls = 0;
  let writtenPayload = null;
  const requestClient = {
    async sendRequest(method, params) {
      if (method === "thread/list") {
        listCalls += 1;
        if (failThreadLists) throw new Error("fixture listing rejection");
        const page = params.cursor ? Number(params.cursor.slice(1)) : 0;
        return {
          data: [{ id: `thread-${page}`, ...(page === 0 ? { project_id: "fixture-project" } : { project: null }), status: "notLoaded", title: `Task ${page}` }],
          nextCursor: page < 199 || truncateThreadLists ? `p${page + 1}` : null,
        };
      }
      if (method === "config/read") return { codexHome: "C:\\Fixture\\.codex" };
      if (method === "fs/writeFile") {
        writeCalls += 1;
        writtenPayload = JSON.parse(Buffer.from(params.dataBase64, "base64").toString("utf8"));
        return {};
      }
      throw new Error(`unexpected request ${method}`);
    },
  };
  reliability.assignLocalRuntime(async () => ({ value: {} }), requestClient);

  const windowStartedAt = clock;
  reliability.scheduleNativeInventoryHydration();
  await drainAsyncWork();
  await advanceTo(windowStartedAt + 120_000);

  assert.equal(reliability.state.counters.inventoryHydrationRuns, 3, "a complete unchanged inventory must scan at initial load and sixty-second intervals");
  assert.equal(listCalls, 600, "three complete 200-page scans are expected in the fixed clock window");
  assert.equal(reliability.state.threadInventories.get("local").threads.length, 200);
  assert.equal(reliability.state.threadInventories.get("local").truncated, false);
  const fullScanListCalls = listCalls;

  const backgroundTarget = new FixtureElement();
  backgroundTarget.insideFixturePanel = true;
  reliability.state.panel = new FixtureElement();
  const backgroundRenderStart = reliability.state.counters.renders;
  const backgroundScanStart = reliability.state.counters.inventoryHydrationRuns;
  for (let index = 0; index < 200; index += 1) {
    reliability.schedule([{ target: backgroundTarget, addedNodes: [], removedNodes: [] }]);
  }
  flushAnimationFrames();
  assert.equal(reliability.state.counters.renders - backgroundRenderStart, 0, "renderer-owned mutations must not trigger render work");
  assert.equal(reliability.state.counters.inventoryHydrationRuns - backgroundScanStart, 0, "renderer-owned mutations must not trigger inventory scans");

  const sidebarTarget = new FixtureElement();
  const sidebarRenderStart = reliability.state.counters.renders;
  const sidebarScanStart = reliability.state.counters.inventoryHydrationRuns;
  for (let index = 0; index < 100; index += 1) {
    reliability.schedule([{ target: sidebarTarget, addedNodes: [], removedNodes: [] }]);
  }
  flushAnimationFrames();
  assert.equal(reliability.state.counters.renders - sidebarRenderStart, 1, "a sidebar mutation burst must coalesce into one animation-frame render");
  assert.equal(reliability.state.counters.inventoryHydrationRuns - sidebarScanStart, 0, "non-membership sidebar mutations must not force a full scan");

  const successfulFetchedAt = reliability.state.threadInventories.get("local").fetchedAt;
  clock += 1_000;
  failThreadLists = true;
  await reliability.hydrateNativeInventory();
  await drainAsyncWork();
  const retainedInventory = reliability.state.threadInventories.get("local");
  assert.match(retainedInventory.error, /fixture listing rejection/);
  assert.equal(retainedInventory.fetchedAt, successfulFetchedAt, "a rejected scan must preserve the last successful authority timestamp");
  assert.equal(retainedInventory.attemptedAt, clock, "a failed attempt needs a separate diagnostic timestamp");
  assert.equal(retainedInventory.threads.length, 200, "a rejected scan must retain the complete prior snapshot");

  const writesBeforeRejectedPublication = writeCalls;
  const publishStartedAt = performance.now();
  reliability.scheduleLocalProjectInventoryPublication();
  await drainAsyncWork();
  const statusPublishElapsedMs = performance.now() - publishStartedAt;
  assert.equal(writeCalls, writesBeforeRejectedPublication + 1, "an errored retained listing must keep publishing status through the legacy non-membership contract");
  assert.equal(writtenPayload.publisherVersion, 53, "an errored retained thread listing must not be republished as protocol-54 membership authority");
  failThreadLists = false;
  await reliability.hydrateNativeInventory();
  await drainAsyncWork();
  const recoveredFetchedAt = reliability.state.threadInventories.get("local").fetchedAt;
  const completeMembershipInventory = reliability.state.threadInventories.get("local");
  const nativeResolvedThreads = completeMembershipInventory.threads.map(thread => ({ ...thread }));
  for (const index of [1, 2]) {
    delete nativeResolvedThreads[index].project;
    nativeResolvedThreads[index].project_id = null;
  }
  reliability.state.threadInventories.set("local", { ...completeMembershipInventory, threads: nativeResolvedThreads });
  nativeTasks = [
    new FixtureElement({
      cwd: "C:\\Fixture\\Grouped",
      hoverCardProjectId: "native-project",
      hoverCardProjectLabel: "Native project",
      isGrouped: true,
      isProjectlessHoverCard: false,
    }, {
      "data-app-action-sidebar-thread-host-id": "local",
      "data-app-action-sidebar-thread-id": "thread-1",
      "data-app-action-sidebar-thread-title": "Task 1",
    }),
    new FixtureElement({
      cwd: "C:\\Fixture\\Recent",
      isGrouped: false,
      isProjectlessHoverCard: false,
    }, {
      "data-app-action-sidebar-thread-host-id": "local",
      "data-app-action-sidebar-thread-id": "thread-2",
      "data-app-action-sidebar-thread-title": "Task 2",
    }),
  ];
  reliability.scheduleLocalProjectInventoryPublication(true);
  await drainAsyncWork();
  assert.equal(reliability.state.localInventoryPublisherError, null, "publication must recover after a successful direct thread refresh");
  assert.ok(writtenPayload, "the full-source publisher must write a status envelope");
  assert.equal(writtenPayload.publisherVersion, 54, "a recovered complete listing must restore protocol-54 membership authority");
  assert.equal(writtenPayload.threads.find(thread => thread.id === "thread-0").projectId, "fixture-project", "publisher membership authority must normalize alternate app-server project-id shapes");
  assert.equal(writtenPayload.threads.find(thread => thread.id === "thread-1").projectId, "native-project", "publisher membership authority must preserve current native project ownership when thread/list reports a nullable membership field");
  assert.equal(Object.prototype.hasOwnProperty.call(writtenPayload.threads.find(thread => thread.id === "thread-2"), "projectId"), false, "a current native Recent chat must remain projectless in the compact publisher payload");
  assert.equal(reliability.taskFromThread(reliability.parseInventoryPayload(writtenPayload).threads.find(thread => thread.id === "thread-2"), "remote").isProjectless, true, "a current native Recent chat must round-trip as authoritative projectless membership");
  assert.equal(writtenPayload.threadScopeGeneratedAt, new Date(recoveredFetchedAt).toISOString(), "publication must report the recovered successful full-scan timestamp");

  nativeTasks = [];
  reliability.scheduleLocalProjectInventoryPublication(true);
  await drainAsyncWork();
  assert.equal(writtenPayload.publisherVersion, 53, "flat nullable membership without a native row must not claim protocol-54 authority");
  const nullableRoundTrip = reliability.parseInventoryPayload(writtenPayload).threads.find(thread => thread.id === "thread-1");
  assert.equal(nullableRoundTrip.projectMembershipKnown, false, "flat nullable membership must remain unknown after publication without a native row");

  reliability.state.threadInventories.set("local", completeMembershipInventory);
  const mixedMembershipThreads = completeMembershipInventory.threads.map(thread => ({ ...thread }));
  delete mixedMembershipThreads[2].project;
  reliability.state.threadInventories.set("local", { ...completeMembershipInventory, threads: mixedMembershipThreads });
  reliability.scheduleLocalProjectInventoryPublication(true);
  await drainAsyncWork();
  assert.equal(writtenPayload.publisherVersion, 53, "one unknown membership record must downgrade only the envelope-wide authority contract");
  const mixedRoundTrip = reliability.parseInventoryPayload(writtenPayload);
  const knownProjectless = mixedRoundTrip.threads.find(thread => thread.id === "thread-1");
  const unknownMembership = mixedRoundTrip.threads.find(thread => thread.id === "thread-2");
  assert.equal(knownProjectless.projectMembershipKnown, true, "known projectless membership must survive a mixed v53 envelope");
  assert.equal(reliability.taskFromThread(knownProjectless, "remote").isGrouped, false, "known projectless membership must not fall back to cwd grouping");
  assert.equal(unknownMembership.projectMembershipKnown, false, "an unknown record in a mixed v53 envelope must retain cwd fallback semantics");
  reliability.state.threadInventories.set("local", completeMembershipInventory);
  reliability.scheduleLocalProjectInventoryPublication(true);
  await drainAsyncWork();
  assert.equal(writtenPayload.publisherVersion, 54, "restoring complete membership must restore the envelope-wide authority contract");

  const firstPublishedAt = reliability.state.localInventoryPublishedAt;
  const firstWriteCalls = writeCalls;
  const publisherTimerId = reliability.state.localInventoryPublisherTimer;
  const publisherTimer = timers.get(publisherTimerId);
  assert.ok(publisherTimer, "a successful publication must schedule its next heartbeat");
  timers.delete(publisherTimerId);
  clock = publisherTimer.due;
  publisherTimer.callback(...publisherTimer.args);
  for (let turn = 0; turn < 20 && reliability.state.localInventoryPublisherPending; turn += 1) {
    await new Promise(resolve => setImmediate(resolve));
  }
  assert.equal(writeCalls, firstWriteCalls + 1, "the publisher heartbeat must write without waiting for an animation frame");
  assert.ok(reliability.state.localInventoryPublishedAt > firstPublishedAt, "the background heartbeat must advance publication freshness");
  assert.ok(animationFrames.size > 0, "the regression must leave the requested animation frame unflushed");
  flushAnimationFrames();
  await drainAsyncWork();

  const inventoryBeforeRefreshGap = reliability.state.threadInventories.get("local");
  const writesBeforeRefreshGap = writeCalls;
  const refreshGapTimerId = reliability.state.localInventoryPublisherTimer;
  const refreshGapTimer = timers.get(refreshGapTimerId);
  assert.ok(refreshGapTimer, "the publisher must remain armed before a transient inventory refresh gap");
  timers.delete(refreshGapTimerId);
  reliability.state.threadInventories.delete("local");
  clock = refreshGapTimer.due;
  refreshGapTimer.callback(...refreshGapTimer.args);
  await drainAsyncWork();
  assert.equal(writeCalls, writesBeforeRefreshGap, "the publisher must not write without an authoritative local inventory");
  const retryTimerId = reliability.state.localInventoryPublisherTimer;
  const retryTimer = timers.get(retryTimerId);
  assert.ok(retryTimer, "a transient missing inventory must re-arm the publisher retry");
  reliability.state.threadInventories.set("local", inventoryBeforeRefreshGap);
  timers.delete(retryTimerId);
  clock = retryTimer.due;
  retryTimer.callback(...retryTimer.args);
  for (let turn = 0; turn < 20 && reliability.state.localInventoryPublisherPending; turn += 1) {
    await new Promise(resolve => setImmediate(resolve));
  }
  assert.equal(writeCalls, writesBeforeRefreshGap + 1, "the re-armed publisher must recover after the local inventory returns");
  flushAnimationFrames();
  await drainAsyncWork();

  const writesBeforeExternalWake = writeCalls;
  const dormantTimerId = reliability.state.localInventoryPublisherTimer;
  assert.ok(timers.has(dormantTimerId), "the external wake regression requires an armed renderer timer");
  assert.equal(reliability.publishInventoryHeartbeat(), true);
  await drainAsyncWork();
  assert.equal(timers.has(dormantTimerId), false, "an external wake must discard the renderer timer that may be frozen");
  assert.equal(writeCalls, writesBeforeExternalWake + 1, "an external wake must publish immediately instead of trusting the armed timer");

  failThreadLists = false;
  truncateThreadLists = true;
  clock += 1_000;
  await reliability.hydrateNativeInventory();
  await drainAsyncWork();
  const retainedAfterTruncation = reliability.state.threadInventories.get("local");
  assert.equal(retainedAfterTruncation.attemptTruncated, true);
  assert.match(retainedAfterTruncation.error, /incomplete inventory/);
  assert.equal(retainedAfterTruncation.fetchedAt, recoveredFetchedAt, "a truncated attempt must not move the recovered authority timestamp");
  assert.equal(retainedAfterTruncation.truncated, false, "the retained prior complete snapshot must remain publishable");
  assert.equal(retainedAfterTruncation.threads.length, 200);

  clock = reliability.state.localInventoryPublishedAt + 180_001;
  assert.equal(reliability.readiness().publisherReady, false, "publisher readiness must expire when no heartbeat reaches disk within the remote validity window");

  console.log(JSON.stringify({
    backgroundMutationBatches: 200,
    preDomReinjectionConverged: true,
    backgroundRenderDelta: 0,
    backgroundScanDelta: 0,
    backgroundPublisherWithoutAnimationFrame: true,
    externalHeartbeatBypassesFrozenTimer: true,
    publisherRetryAfterInventoryRefreshGap: true,
    stalePublisherReadinessRejected: true,
    fixedClockWindowMs: 120_000,
    fullInventoryPagesPerScan: 200,
    fullInventoryScans: 3,
    fullScanListCalls,
    sidebarMutationBatches: 100,
    sidebarRenderDelta: 1,
    sidebarScanDelta: 0,
    statusPublishElapsedMs: Number(statusPublishElapsedMs.toFixed(3)),
    successfulTimestampRetainedAfterRejection: true,
    successfulTimestampRetainedAfterTruncation: true,
    totalListAttempts: listCalls,
  }));
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
