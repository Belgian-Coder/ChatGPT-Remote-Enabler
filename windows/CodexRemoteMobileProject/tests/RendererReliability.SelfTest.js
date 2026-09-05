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
  .replace("  return install();\n})();", `
  discoverHostNames = () => ({ availability: new Map(), names: new Map(), registeredProjects: new Map(), runtimes: new Map() });
  discoverRemoteRuntimes = () => new Map();
  render = () => {
    state.counters.renders += 1;
    state.scheduledFrame = null;
    scheduleNativeInventoryHydration();
    return { active: state.active, version: VERSION };
  };
  return { assignLocalRuntime, hydrateNativeInventory, schedule, scheduleLocalProjectInventoryPublication, scheduleNativeInventoryHydration, state };
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
  constructor() { this.nodeType = 1; }
  closest() { return null; }
  contains(candidate) { return candidate === this || candidate?.insideFixturePanel === true; }
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

const document = {
  addEventListener() {},
  getElementById: () => null,
  querySelector(selector) { return selector === '[aria-label="Project sidebar options"]' ? new FixtureElement() : null; },
  querySelectorAll: () => [],
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
vm.runInContext(testSource, context, { filename: rendererPath });
const reliability = context.__rendererReliabilityTest;

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
  let failThreadLists = false;
  let truncateThreadLists = false;
  let listCalls = 0;
  let writtenPayload = null;
  const requestClient = {
    async sendRequest(method, params) {
      if (method === "thread/list") {
        listCalls += 1;
        if (failThreadLists) throw new Error("fixture listing rejection");
        const page = params.cursor ? Number(params.cursor.slice(1)) : 0;
        return {
          data: [{ id: `thread-${page}`, status: "notLoaded", title: `Task ${page}` }],
          nextCursor: page < 199 || truncateThreadLists ? `p${page + 1}` : null,
        };
      }
      if (method === "config/read") return { codexHome: "C:\\Fixture\\.codex" };
      if (method === "fs/writeFile") {
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

  const publishStartedAt = performance.now();
  reliability.scheduleLocalProjectInventoryPublication();
  await drainAsyncWork();
  const statusPublishElapsedMs = performance.now() - publishStartedAt;
  assert.equal(reliability.state.localInventoryPublisherError, null, "retained authority must still permit status publication after a scan rejection");
  assert.ok(writtenPayload, "the full-source publisher must write a status envelope");
  assert.equal(writtenPayload.threadScopeGeneratedAt, new Date(successfulFetchedAt).toISOString(), "publication must report the last successful full-scan timestamp");

  failThreadLists = false;
  truncateThreadLists = true;
  clock += 1_000;
  await reliability.hydrateNativeInventory();
  await drainAsyncWork();
  const retainedAfterTruncation = reliability.state.threadInventories.get("local");
  assert.equal(retainedAfterTruncation.attemptTruncated, true);
  assert.match(retainedAfterTruncation.error, /incomplete inventory/);
  assert.equal(retainedAfterTruncation.fetchedAt, successfulFetchedAt, "a truncated attempt must not move the authority timestamp");
  assert.equal(retainedAfterTruncation.truncated, false, "the retained prior complete snapshot must remain publishable");
  assert.equal(retainedAfterTruncation.threads.length, 200);

  console.log(JSON.stringify({
    backgroundMutationBatches: 200,
    backgroundRenderDelta: 0,
    backgroundScanDelta: 0,
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
