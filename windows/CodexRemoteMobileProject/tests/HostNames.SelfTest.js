"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const originalSource = fs.readFileSync(rendererPath, "utf8").replace(/\r\n/gu, "\n");
const testSource = originalSource
  .replace("(() => {", "globalThis.__hostFlowTest = (() => {")
  .replace("  return installWhenDocumentReady(api, state, install, probe);\n})();", "  return { collectModel, discoverHostNames, hostName, metadataFromRow, state, uninstall };\n})();");
assert.notEqual(testSource, originalSource, "full renderer test adapter must replace the production entrypoint");

class FixtureElement {
  constructor(group = null, props = {}, attributes = {}) {
    this.nodeType = 1;
    this.parentElement = null;
    this.children = [];
    this.attributes = attributes;
    if (group || Object.keys(props).length) this.__reactFiber$fixture = { memoizedProps: { group, ...props }, memoizedState: null, return: null, updateQueue: null };
  }
  get isConnected() { return true; }
  closest() { return null; }
  contains(candidate) { return candidate === this || this.children.includes(candidate); }
  getAttribute(name) { return this.attributes[name] ?? (name === "aria-label" ? this.ariaLabel ?? null : null); }
  hasAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attributes, name); }
  matches() { return false; }
  querySelector() { return null; }
  querySelectorAll() { return []; }
}

const storage = new Map();
let nativeProjects = [];
let nativeTasks = [];
const document = {
  addEventListener() {},
  removeEventListener() {},
  getElementById: () => null,
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; },
  querySelectorAll(selector) {
    if (selector === '[data-app-action-sidebar-thread-row]') return nativeTasks;
    if (selector === '[data-app-action-sidebar-thread-row],[aria-label]') return [...nativeTasks, ...nativeProjects];
    if (selector === '[data-sidebar-project-kind][role="listitem"]'
      || selector === '[data-sidebar-project-kind="remote"][role="listitem"]') return nativeProjects;
    return [];
  },
};

const environmentPrefix = "env" + "_";
const hostId = `remote-control:${environmentPrefix}fixture_primary`;
const olderHostId = `remote-control:${environmentPrefix}fixture_older`;
const transientHostId = `remote-control:${environmentPrefix}fixture_transient`;
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
const firstModel = flow.collectModel();
assert.equal(firstModel.hosts.map((host) => host.id).join("|"), `local|${hostId}`, "the authoritative local host identity must always lead device hosts");
assert.equal(firstModel.hosts[0].name, "Local device");
assert.equal(firstModel.projects.find((project) => project.hostId === hostId)?.tasksAuthoritative, true, "a fresh scoped inventory must mark its empty project membership authoritative");
assert.equal(firstModel.projects.find((project) => project.hostId === hostId)?.taskStatusAuthoritative, true, "empty authoritative membership must also prove that no child is busy");
assert.equal(firstModel.projects.find((project) => project.hostId === hostId)?.taskUnreadAuthoritative, true, "empty authoritative membership must also prove that no child is unread");

const offlineStatusHostId = `remote-control:${environmentPrefix}fixture_status_offline`;
const activeStatusHostId = `remote-control:${environmentPrefix}fixture_status_active`;
const connectingStatusHostId = `remote-control:${environmentPrefix}fixture_status_connecting`;
nativeProjects = [new FixtureElement(null, {
  connectionFixtures: [
    { displayName: "Offline status", hostId: offlineStatusHostId, status: "offline" },
    { displayName: "Active status", hostId: activeStatusHostId, state: "active" },
    { displayName: "Connecting status", hostId: connectingStatusHostId, status: "connecting" },
  ],
})];
flow.state.hostDiscoveryDirty = true;
const triStateDiscovery = flow.discoverHostNames();
assert.equal(triStateDiscovery.availability.get(offlineStatusHostId), false, "an explicit offline status must remain authoritative");
assert.equal(triStateDiscovery.availability.get(activeStatusHostId), true, "an explicit active state must remain authoritative");
assert.equal(triStateDiscovery.availability.has(connectingStatusHostId), false, "a transitional status must remain unknown");

const localThreadId = "11111111-1111-4111-8111-111111111111";
const localThread = (threadStatus, hasUnreadTurn) => ({
  cwd: "C:\\Fixture\\Local",
  hasUnreadTurn,
  id: localThreadId,
  projectId: "local-project",
  status: threadStatus,
});
nativeProjects = [new FixtureElement({
  cwd: "C:\\Fixture\\Local",
  label: "Local project",
  projectId: "local-project",
  projectKind: "local",
})];
flow.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), truncated: false, threads: [localThread("active", false)] });
let localProject = flow.collectModel().projects.find((project) => project.projectId === "local-project");
assert.equal(localProject.taskStatusAuthoritative, true);
assert.equal(localProject.taskUnreadAuthoritative, true);
assert.equal(localProject.tasksAuthoritative, true);
assert.equal(localProject.tasks[0].statusType, "loading", "current local app-server status must establish the busy phase");
flow.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), truncated: false, threads: [localThread("completed", true)] });
localProject = flow.collectModel().projects.find((project) => project.projectId === "local-project");
assert.equal(localProject.tasks[0].statusType, "idle");
assert.equal(localProject.tasks[0].unread, true, "current local app-server unread state must establish the completed-unread phase");
flow.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), truncated: false, threads: [localThread("completed", false)] });
localProject = flow.collectModel().projects.find((project) => project.projectId === "local-project");
assert.equal(localProject.tasks[0].unread, false, "current local app-server unread state must establish the read phase");
flow.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), truncated: false, threads: [localThread("completed", undefined)] });
localProject = flow.collectModel().projects.find((project) => project.projectId === "local-project");
assert.equal(localProject.taskStatusAuthoritative, true, "known completion stays authoritative when unread metadata is absent");
assert.equal(localProject.taskUnreadAuthoritative, false, "missing unread metadata must remain independently unknown");
assert.equal(localProject.tasksAuthoritative, false, "the combined marker remains conservative when either signal is unknown");
nativeTasks = [new FixtureElement(null, {
  cwd: "C:\\Fixture\\Local",
  hoverCardProjectId: "local-project",
  hoverCardProjectLabel: "Local project",
  isGrouped: true,
  isProjectlessHoverCard: false,
}, {
  "data-app-action-sidebar-thread-host-id": "local",
  "data-app-action-sidebar-thread-id": localThreadId,
  "data-app-action-sidebar-thread-title": "Native project task",
})];
const freshThreadWithoutMembership = localThread("completed", false);
delete freshThreadWithoutMembership.projectId;
freshThreadWithoutMembership.workspaceKind = "repository";
flow.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), truncated: false, threads: [freshThreadWithoutMembership] });
localProject = flow.collectModel().projects.find((project) => project.projectId === "local-project");
assert.equal(localProject.tasks[0].projectId, "local-project", "a fresh listing without a membership field must preserve current native project ownership");
assert.equal(flow.collectModel().recents.some(group => group.tasks.some(task => task.conversationId === localThreadId)), false, "missing membership metadata must retain cwd/native grouping instead of claiming projectlessness");
const explicitProjectWithoutCwd = { ...freshThreadWithoutMembership, projectId: "local-project" };
delete explicitProjectWithoutCwd.cwd;
flow.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), truncated: false, threads: [explicitProjectWithoutCwd] });
localProject = flow.collectModel().projects.find((project) => project.projectId === "local-project");
assert.equal(localProject.tasks[0].cwd, "C:\\Fixture\\Local", "native cwd must survive when an authoritative direct thread omits cwd");
assert.equal(localProject.tasks[0].isProjectless, false, "an authoritative project id without cwd must not mark a project thread as projectless");
const explicitNestedProjectless = { ...freshThreadWithoutMembership, project: null };
flow.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), truncated: false, threads: [explicitNestedProjectless] });
let projectlessModel = flow.collectModel();
assert.equal(projectlessModel.projects.find((project) => project.projectId === "local-project")?.tasks.some(task => task.conversationId === localThreadId) ?? false, false, "an explicit nested null project must remove stale native project ownership");
assert.equal(projectlessModel.recents.some(group => group.tasks.some(task => task.conversationId === localThreadId)), true, "an explicit nested null project must classify the thread as projectless");
flow.state.threadInventories.set("local", { error: "temporary listing failure", fetchedAt: Date.now(), truncated: false, threads: [{ ...localThread("completed", false), projectId: null }] });
flow.state.verifiedThreadIds.set("local", { ids: new Set([localThreadId]), verifiedAt: Date.now() });
assert.equal(flow.metadataFromRow(nativeTasks[0]).projectId, "local-project", "the fixture must expose current native project membership");
localProject = flow.collectModel().projects.find((project) => project.projectId === "local-project");
assert.equal(localProject.tasks[0].projectId, "local-project", "an errored retained direct listing must not clear current native project membership");
assert.equal(flow.collectModel().recents.some(group => group.tasks.some(task => task.conversationId === localThreadId)), false, "an errored retained direct listing must not move a native project task into Recents");
flow.state.threadInventories.delete("local");
flow.state.verifiedThreadIds.delete("local");
nativeProjects = [];
nativeTasks = [];

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

nativeProjects = [new FixtureElement({
  cwd: "D:\\Fixture\\Transient",
  hostDisplayName: "Transient workstation",
  hostId: transientHostId,
  label: "Transient project",
  projectId: "transient-project",
  projectKind: "remote",
})];
flow.state.hostDiscoveryDirty = true;
flow.discoverHostNames();
const eagerlyRemembered = JSON.parse(storage.get("codex-remote-mobile-host-names-v1") ?? "{}");
assert.equal(eagerlyRemembered[transientHostId], "Transient workstation", "trusted discovery must persist a name before the host reaches the rendered model");
assert.equal(eagerlyRemembered[transientHostId.replace(/^remote-control:/u, "")], "Transient workstation", "durable labels must cover the normalized short identity");

delete context.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__;
delete context.__hostFlowTest;
nativeProjects = [];
vm.runInContext(testSource, context, { filename: rendererPath });
flow = context.__hostFlowTest;
flow.state.remoteProjectInventories.set(hostId, inventory(null, "D:\\Fixture\\Primary"));
assert.equal(hostLabel(flow, hostId), "Peer desktop", "renderer reinjection must restore the per-host confirmed name");
flow.state.remoteProjectInventories.set(transientHostId, inventory(null, "D:\\Fixture\\Transient"));
assert.equal(hostLabel(flow, transientHostId), "Transient workstation", "a renderer restart without live discovery must retain a previously observed label");

console.log(JSON.stringify({
  configuredKeyNormalized: true,
  initialNeutral: true,
  metadataArrivalRenamed: true,
  preRenderDiscoveryPersisted: true,
  olderPeerNeutral: true,
  reinjectionRestored: true,
  shortAliasPersisted: true,
  syntheticOverwriteRejected: true,
}));
