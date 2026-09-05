"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const originalSource = fs.readFileSync(rendererPath, "utf8").replace(/\r\n/gu, "\n");
const testSource = originalSource
  .replace("(() => {", "globalThis.__hostFlowTest = (() => {")
  .replace("  return install();\n})();", "  return { collectModel, hostName, state, uninstall };\n})();");
assert.notEqual(testSource, originalSource, "full renderer test adapter must replace the production entrypoint");

class FixtureElement {
  constructor(group = null) {
    this.nodeType = 1;
    this.parentElement = null;
    this.children = [];
    if (group) this.__reactFiber$fixture = { memoizedProps: { group }, memoizedState: null, return: null, updateQueue: null };
  }
  get isConnected() { return true; }
  closest() { return null; }
  contains(candidate) { return candidate === this || this.children.includes(candidate); }
  getAttribute(name) { return name === "aria-label" ? this.ariaLabel ?? null : null; }
  hasAttribute() { return false; }
  matches() { return false; }
  querySelector() { return null; }
  querySelectorAll() { return []; }
}

const storage = new Map();
let nativeProjects = [];
const document = {
  addEventListener() {},
  removeEventListener() {},
  getElementById: () => null,
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; },
  querySelectorAll(selector) {
    if (selector === '[data-sidebar-project-kind][role="listitem"]'
      || selector === '[data-sidebar-project-kind="remote"][role="listitem"]') return nativeProjects;
    return [];
  },
};

const environmentPrefix = "env" + "_";
const hostId = `remote-control:${environmentPrefix}fixture_primary`;
const olderHostId = `remote-control:${environmentPrefix}fixture_older`;
const configuredShortId = `${environmentPrefix}fixture_configured`;
const configuredHostId = `remote-control:${configuredShortId}`;
const context = vm.createContext({
  __CODEX_REMOTE_MOBILE_CONFIG__: {
    hostDisplayNames: { [configuredShortId]: "Configured peer" },
    localDisplayName: "Local device",
    singleRemoteDisplayName: null,
  },
  CSS: { escape: value => String(value) },
  Element: FixtureElement,
  Node: FixtureElement,
  TextDecoder,
  TextEncoder,
  cancelAnimationFrame() {},
  clearInterval,
  clearTimeout,
  console,
  crypto: { randomUUID: () => "host-flow-fixture" },
  document,
  globalThis: null,
  localStorage: {
    getItem: key => storage.get(key) ?? null,
    removeItem: key => storage.delete(key),
    setItem: (key, value) => storage.set(key, String(value)),
  },
  navigator: { locks: { request: async (_name, _options, callback) => callback({}) } },
  performance: { now: () => 0 },
  queueMicrotask,
  requestAnimationFrame: () => 1,
  setInterval,
  setTimeout,
});
context.globalThis = context;

function inventory(displayName, cwd) {
  const now = Date.now();
  return {
    error: null,
    fetchedAt: now,
    generatedAt: now,
    hostDisplayName: displayName,
    pending: false,
    projects: [{ cwd, name: "Fixture project", rootPaths: [cwd] }],
    projectsAuthoritative: true,
    publisherVersion: 53,
    retryAt: 0,
    tasks: new Map(),
    threadScope: "user-visible",
    threadScopeGeneratedAt: now,
    threads: [],
    threadsAuthoritative: true,
  };
}

function hostLabel(flow, id) {
  return flow.collectModel().hosts.find((host) => host.id === id)?.name;
}

vm.runInContext(testSource, context, { filename: rendererPath });
let flow = context.__hostFlowTest;
flow.state.remoteProjectInventories.set(hostId, inventory(null, "D:\\Fixture\\Primary"));
assert.equal(hostLabel(flow, hostId), "Remote device", "an initially unnamed runtime must use a neutral label");
assert.doesNotMatch(hostLabel(flow, hostId), /fixture_primary/iu, "a raw environment identity must never enter the UI label");

flow.state.remoteProjectInventories.set(hostId, inventory("Peer desktop", "D:\\Fixture\\Primary"));
assert.equal(hostLabel(flow, hostId), "Peer desktop", "direct inventory metadata must update the rendered device name");
const remembered = JSON.parse(storage.get("codex-remote-mobile-host-names-v1") ?? "{}");
assert.equal(remembered[hostId], "Peer desktop", "confirmed names must persist by normalized host identity");

nativeProjects = [new FixtureElement({
  cwd: "D:\\Fixture\\Primary",
  hostDisplayName: `Remote ${environmentPrefix}fixture_primary`,
  hostId,
  label: "Fixture project",
  projectId: "fixture-project",
  projectKind: "remote",
})];
flow.state.hostDiscoveryDirty = true;
assert.equal(hostLabel(flow, hostId), "Peer desktop", "synthetic native metadata must not overwrite a confirmed inventory name");

flow.state.remoteProjectInventories.set(olderHostId, inventory(null, "D:\\Fixture\\Older"));
assert.equal(hostLabel(flow, olderHostId), "Remote device", "an older peer without display metadata must stay neutral");
assert.notEqual(hostLabel(flow, olderHostId), "Peer desktop", "an unnamed peer must not borrow another host's name");

flow.state.remoteProjectInventories.set(configuredHostId, inventory(null, "D:\\Fixture\\Configured"));
assert.equal(hostLabel(flow, configuredHostId), "Configured peer", "short configured identities must resolve after runtime normalization");

delete context.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__;
delete context.__hostFlowTest;
nativeProjects = [];
vm.runInContext(testSource, context, { filename: rendererPath });
flow = context.__hostFlowTest;
flow.state.remoteProjectInventories.set(hostId, inventory(null, "D:\\Fixture\\Primary"));
assert.equal(hostLabel(flow, hostId), "Peer desktop", "renderer reinjection must restore the per-host confirmed name");

console.log(JSON.stringify({
  configuredKeyNormalized: true,
  initialNeutral: true,
  metadataArrivalRenamed: true,
  olderPeerNeutral: true,
  reinjectionRestored: true,
  syntheticOverwriteRejected: true,
}));
