"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const originalSource = fs.readFileSync(rendererPath, "utf8");
const testSource = originalSource
  .replace("(() => {", "globalThis.__navigationTest = (() => {")
  .replace("Object.freeze([750, 2500])", "Object.freeze([1, 2])")
  .replace("const TASK_ACTION_FEEDBACK_MS = 12000;", "const TASK_ACTION_FEEDBACK_MS = 5;")
  .replace("  return installWhenDocumentReady(api, state, install, probe);\n})();", `  return {
    state, archiveTask, canDirectArchiveTask, markPendingArchivedTask, openNativeTask, pendingArchiveKey, reconcilePendingArchivedTask,
    recoverUnconfirmedRemoteSteer, rememberTaskActivation, retainRecentTaskActivations, suppressPendingArchivedTasks,
    configure(fixture) {
      confirmRemoteTaskMembership = async () => fixture.membershipPromise ?? fixture.membership !== false;
      nativeNavigationDispatcher = () => fixture.navigate;
      discoverHostNames = () => ({ runtimes: new Map() });
      discoverRemoteRuntimes = () => new Map();
      refreshLocalRegisteredProjects = async () => {
        if (fixture.bridgeUnavailable) throw new Error("Local project-state bridge is unavailable");
        return state.localRegisteredProjects;
      };
      registerRemoteProjectAndOpen = async (project) => {
        fixture.registrations += 1;
        state.localRegisteredProjects.set("registered-project", {
          cwd: project.cwd, hostId: project.hostId, projectId: "registered-project",
        });
        fixture.hydrated = true;
      };
      revealNativeProjects = () => {
        fixture.projectReveals = (fixture.projectReveals ?? 0) + 1;
        fixture.nativeProject = fixture.revealedNativeProject ?? fixture.nativeProject;
        return true;
      };
      nativeProjectItem = () => fixture.nativeProject;
      nativeThreadRow = () => fixture.hydrated ? fixture.nativeRow : null;
      invokeNativeElement = (element) => { element.click(); return true; };
      requestDeviceRefresh = async () => {
        fixture.refreshes = (fixture.refreshes ?? 0) + 1;
        if (fixture.onRefresh) await fixture.onRefresh();
        return fixture.refreshPromise ?? fixture.refreshResult ?? { complete: true };
      };
      schedule = () => { fixture.schedules = (fixture.schedules ?? 0) + 1; };
    },
  };\n})();`);
assert.notEqual(testSource, originalSource, "test adapter must replace startup");

const context = vm.createContext({
  TextDecoder, TextEncoder, clearInterval, clearTimeout, console,
  crypto: { randomUUID: () => "task-navigation-test" },
  document: { addEventListener() {}, querySelector: () => null, querySelectorAll: () => [], removeEventListener() {} },
  localStorage: { getItem: () => null, removeItem() {}, setItem() {} },
  setInterval, setTimeout,
});
context.globalThis = context;
vm.runInContext(testSource, context, { filename: rendererPath });

const navigation = context.__navigationTest;
const nativeRow = { isConnected: true, clicks: 0, click() { this.clicks += 1; } };
const fixture = {
  hydrated: false,
  navigate() {},
  nativeProject: { isConnected: true, querySelector: () => null },
  nativeRow,
  registrations: 0,
};
navigation.configure(fixture);
navigation.state.queryClient = { invalidateQueries: () => { fixture.invalidations = (fixture.invalidations ?? 0) + 1; } };

const hostId = "remote-control:fixture-host";
const project = { cwd: "D:\\Projects\\Infrastructure", hostId, key: "remote-infrastructure", kind: "project", name: "Infrastructure", projectId: null };
const task = { conversationId: "01a07ab9-07e9-7671-a2b9-e99236f4e986", conversationKey: "01a07ab9-07e9-7671-a2b9-e99236f4e986", hostId };

(async () => {
  const opened = await navigation.openNativeTask(task, project);
  assert.equal(opened, true, "a task in an inventory-only remote project must open");
  assert.equal(fixture.registrations, 1, "the missing remote project must be registered once");
  assert.equal(fixture.invalidations, 1, "native project state must be refreshed after registration");
  assert.equal(nativeRow.clicks, 1, "navigation must retry through the hydrated native task row");
  assert.equal(navigation.state.pendingTaskOpens.size, 0, "the navigation lock must always be released");
  assert.equal(navigation.state.lastAction.mode, "registered-remote-project");

  fixture.hydrated = false;
  fixture.registrations = 0;
  nativeRow.clicks = 0;
  const toggle = { click() { fixture.hydrated = true; } };
  fixture.nativeProject = { isConnected: true, querySelector: () => toggle };
  const registeredProject = { ...project, projectId: "registered-project" };
  fixture.bridgeUnavailable = true;
  const reopened = await navigation.openNativeTask(task, registeredProject);
  assert.equal(reopened, true, "a synthetic task in an existing remote project must hydrate and open");
  assert.equal(fixture.registrations, 0, "an existing remote project must not be registered again");
  assert.equal(nativeRow.clicks, 1, "expanding the native project must expose and invoke the task row");
  fixture.bridgeUnavailable = false;

  fixture.hydrated = false;
  fixture.projectReveals = 0;
  fixture.revealedNativeProject = { isConnected: true, querySelector: () => toggle };
  fixture.nativeProject = null;
  nativeRow.clicks = 0;
  const revealed = await navigation.openNativeTask(task, registeredProject);
  assert.equal(revealed, true, "a task beyond the native five-project cap must open");
  assert.equal(fixture.projectReveals, 1, "the native project list must be revealed on demand");
  assert.equal(nativeRow.clicks, 1, "the revealed native task row must be invoked");

  fixture.hydrated = false;
  fixture.membership = false;
  nativeRow.clicks = 0;
  const blocked = await navigation.openNativeTask(task, registeredProject);
  assert.equal(blocked, false, "stale synthetic navigation must fail closed");
  assert.equal(nativeRow.clicks, 0, "unconfirmed membership must never invoke a native row");
  assert.match(navigation.state.lastAction.error, /fresh membership could not be confirmed/u);

  fixture.hydrated = true;
  nativeRow.clicks = 0;
  const connectedButArchived = await navigation.openNativeTask(task, registeredProject);
  assert.equal(connectedButArchived, false, "a connected native row must still require current remote membership");
  assert.equal(nativeRow.clicks, 0, "cached connected rows must not bypass archive membership checks");
  fixture.hydrated = false;

  // Cancelling a deferred activation must leave the current task untouched.
  fixture.membership = true;
  let resolveMembership;
  fixture.membershipPromise = new Promise(resolve => { resolveMembership = resolve; });
  const pendingOpen = navigation.openNativeTask(task, registeredProject);
  await new Promise(resolve => setImmediate(resolve));
  navigation.state.taskOpenGeneration += 1;
  resolveMembership(true);
  assert.equal(await pendingOpen, false, "a newer activation cancels an older membership read");
  assert.equal(nativeRow.clicks, 0);
  fixture.membershipPromise = new Promise(resolve => { resolveMembership = resolve; });
  const disposedOpen = navigation.openNativeTask(task, registeredProject);
  await new Promise(resolve => setImmediate(resolve));
  navigation.state.disposed = true;
  resolveMembership(true);
  assert.equal(await disposedOpen, false, "disposed renderers cannot complete navigation");
  assert.equal(nativeRow.clicks, 0);
  navigation.state.disposed = false;
  fixture.membershipPromise = null;

  const archiveKey = navigation.pendingArchiveKey(task);
  assert.equal(navigation.markPendingArchivedTask(task, false), true);
  let archiveTasks = new Map([[archiveKey, { ...task }]]);
  navigation.suppressPendingArchivedTasks(archiveTasks);
  assert.equal(archiveTasks.has(archiveKey), false, "an invoked archive must disappear before the sidebar mutation arrives");
  const archiveRecord = navigation.state.pendingArchivedTasks.get(archiveKey);
  navigation.state.threadInventories.set(hostId, {
    error: null, fetchedAt: archiveRecord.requestedAt + 1, threads: [task], truncated: false,
  });
  archiveRecord.attempts = 1;
  assert.equal(navigation.reconcilePendingArchivedTask(archiveKey), true,
    "the first racing inventory that still contains the task must keep it suppressed for a bounded retry");
  archiveRecord.attempts = 2;
  assert.equal(navigation.reconcilePendingArchivedTask(archiveKey), false,
    "a second authoritative inventory may restore a task when archive did not persist");
  assert.equal(navigation.state.pendingArchivedTasks.has(archiveKey), false);

  const localTask = { ...task, conversationId: "22222222-2222-4222-8222-222222222222", hostId: "local" };
  const localArchiveKey = navigation.pendingArchiveKey(localTask);
  assert.equal(navigation.markPendingArchivedTask(localTask, false), true, "local archive actions must use the same immediate suppression path");
  const localArchiveTasks = new Map([[localArchiveKey, localTask]]);
  navigation.suppressPendingArchivedTasks(localArchiveTasks);
  assert.equal(localArchiveTasks.has(localArchiveKey), false, "a local archived chat must disappear before the next periodic inventory read");
  const localArchiveRecord = navigation.state.pendingArchivedTasks.get(localArchiveKey);
  navigation.state.threadInventories.set("local", { error: null, fetchedAt: localArchiveRecord.requestedAt + 1, threads: [], truncated: false });
  assert.equal(navigation.reconcilePendingArchivedTask(localArchiveKey), false, "a fresh local omission must confirm the optimistic archive suppression");

  // Some CLI-created rows have a path title but no mounted native action rail.
  // The Device projects view must still provide a reversible archive action
  // through the same app-server runtime that supplied the authoritative row.
  const pathTask = {
    conversationId: "44444444-4444-4444-8444-444444444444",
    conversationKey: "44444444-4444-4444-8444-444444444444",
    cwd: "//NAS/Data\\Backups\\Infrastructure",
    hostId: "local",
    originalRow: null,
    title: "//NAS/Data\\Backups\\Infrastructure",
  };
  const archiveRequests = [];
  navigation.state.localRuntime = { requestClient: { sendRequest: async (method, params) => { archiveRequests.push({ method, params }); return {}; } } };
  navigation.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), threads: [pathTask], truncated: false });
  assert.equal(navigation.canDirectArchiveTask(pathTask), true, "a synthetic local row with an app-server runtime must expose Archive chat");
  assert.equal(await navigation.archiveTask(pathTask), true, "a synthetic path-titled row must archive through its current app-server runtime");
  assert.equal(archiveRequests.length, 1);
  assert.equal(archiveRequests[0].method, "thread/archive");
  assert.equal(archiveRequests[0].params.threadId, pathTask.conversationId);
  assert.equal(navigation.state.pendingArchivedTasks.has(navigation.pendingArchiveKey(pathTask)), true, "a direct archive must hide the row until authoritative refresh confirms removal");
  navigation.state.pendingArchivedTasks.delete(navigation.pendingArchiveKey(pathTask));

  let releaseArchive;
  archiveRequests.length = 0;
  const deferredArchive = new Promise(resolve => { releaseArchive = resolve; });
  navigation.state.localRuntime = { requestClient: { sendRequest: async (method, params) => { archiveRequests.push({ method, params }); return deferredArchive; } } };
  navigation.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), threads: [pathTask], truncated: false });
  const firstArchive = navigation.archiveTask(pathTask);
  const duplicateArchive = navigation.archiveTask(pathTask);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(archiveRequests.length, 1, "two activations during a slow archive must dispatch one request");
  assert.equal(navigation.state.pendingDirectArchives.has(navigation.pendingArchiveKey(pathTask)), true, "the direct archive must expose its in-flight state");
  releaseArchive({});
  assert.deepEqual(await Promise.all([firstArchive, duplicateArchive]), [true, true]);
  assert.equal(navigation.state.pendingDirectArchives.has(navigation.pendingArchiveKey(pathTask)), false);
  navigation.state.pendingArchivedTasks.delete(navigation.pendingArchiveKey(pathTask));

  // Refresh reconstructs runtime wrapper objects even when the underlying
  // app-server request client is unchanged. That must not cancel the archive.
  archiveRequests.length = 0;
  navigation.state.threadInventories.set("local", { error: "stale", fetchedAt: 0, threads: [pathTask], truncated: true });
  fixture.onRefresh = async () => {
    navigation.state.localRuntime = { requestClient: navigation.state.localRuntime.requestClient };
    navigation.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), threads: [pathTask], truncated: false });
  };
  fixture.refreshResult = { complete: false, error: "unrelated peer unavailable" };
  assert.equal(await navigation.archiveTask(pathTask), true, "archive must survive a refresh that rebuilds the runtime wrapper around the same request client");
  assert.equal(archiveRequests.length, 1, "post-refresh archive must send exactly one request");
  navigation.state.pendingArchivedTasks.delete(navigation.pendingArchiveKey(pathTask));
  fixture.onRefresh = null;
  fixture.refreshResult = null;

  const remotePathTask = { ...pathTask, conversationId: "55555555-5555-4555-8555-555555555555", hostId };
  const remoteRequests = [];
  const remoteClient = { sendRequest: async (method, params) => { remoteRequests.push({ method, params }); return {}; } };
  navigation.state.remoteRuntimeCache.set(hostId, { requestClient: remoteClient });
  navigation.state.threadInventories.set(hostId, { error: "stale", fetchedAt: 0, threads: [remotePathTask], truncated: true });
  fixture.onRefresh = async () => {
    navigation.state.remoteRuntimeCache.set(hostId, { requestClient: remoteClient });
    navigation.state.threadInventories.set(hostId, { error: null, fetchedAt: Date.now(), threads: [remotePathTask], truncated: false });
  };
  assert.equal(await navigation.archiveTask(remotePathTask), true, "remote archive must survive a refreshed wrapper around the same request client");
  assert.equal(remoteRequests.length, 1);
  navigation.state.pendingArchivedTasks.delete(navigation.pendingArchiveKey(remotePathTask));

  remoteRequests.length = 0;
  navigation.state.threadInventories.set(hostId, { error: "stale", fetchedAt: 0, threads: [remotePathTask], truncated: true });
  fixture.onRefresh = async () => {
    navigation.state.remoteRuntimeCache.set(hostId, { requestClient: { sendRequest: async () => ({}) } });
    navigation.state.threadInventories.set(hostId, { error: null, fetchedAt: Date.now(), threads: [remotePathTask], truncated: false });
  };
  assert.equal(await navigation.archiveTask(remotePathTask), false, "archive must fail closed when refresh replaces the app-server request client");
  assert.equal(remoteRequests.length, 0, "a retired request client must never receive the archive request");
  assert.match(navigation.state.taskActionFeedback, /Task runtime changed before archive/u);
  navigation.state.remoteRuntimeCache.delete(hostId);
  fixture.onRefresh = null;

  navigation.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), threads: [pathTask], truncated: false });
  const failingClient = { sendRequest: async () => { throw new Error("archive refused"); } };
  navigation.state.localRuntime = { requestClient: failingClient };
  const schedulesBeforeFailure = fixture.schedules ?? 0;
  const refreshesBeforeFailure = fixture.refreshes ?? 0;
  assert.equal(await navigation.archiveTask(pathTask), false, "a rejected direct archive must fail cleanly");
  await new Promise(resolve => setImmediate(resolve));
  assert.match(navigation.state.taskActionFeedback, /Could not archive.*archive refused/u, "archive failures must be available to the visible sync status");
  assert.ok((fixture.schedules ?? 0) > schedulesBeforeFailure, "archive failures must schedule visible feedback");
  assert.ok((fixture.refreshes ?? 0) > refreshesBeforeFailure, "an uncertain archive outcome must trigger authoritative reconciliation");
  assert.equal(navigation.state.pendingArchivedTasks.has(navigation.pendingArchiveKey(pathTask)), false, "a definitive rejection must restore the hidden row immediately");
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(navigation.state.taskActionFeedback, null, "archive failure feedback must expire without requiring reinjection or a later successful archive");

  const timeoutError = new Error("Archive request timed out");
  timeoutError.code = "CODEX_REMOTE_REQUEST_TIMEOUT";
  navigation.state.localRuntime = { requestClient: { sendRequest: async () => { throw timeoutError; } } };
  navigation.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), threads: [pathTask], truncated: false });
  assert.equal(await navigation.archiveTask(pathTask), false, "an archive timeout must report an uncertain result");
  const timeoutArchiveKey = navigation.pendingArchiveKey(pathTask);
  assert.equal(navigation.state.pendingArchivedTasks.has(timeoutArchiveKey), true, "a timeout must keep the row hidden while its outcome is reconciled");
  assert.equal(navigation.state.pendingArchiveRefreshTimers.has(timeoutArchiveKey), true, "a timeout must schedule bounded authoritative reconciliation");
  const timeoutRecord = navigation.state.pendingArchivedTasks.get(timeoutArchiveKey);
  navigation.state.threadInventories.set("local", { error: null, fetchedAt: timeoutRecord.requestedAt + 1, threads: [], truncated: false });
  assert.equal(navigation.reconcilePendingArchivedTask(timeoutArchiveKey), false, "a fresh omission after timeout must confirm the archive and release pending state");
  assert.equal(navigation.state.pendingArchiveRefreshTimers.has(timeoutArchiveKey), false, "confirmed timeout reconciliation must cancel its remaining timer");

  archiveRequests.length = 0;
  navigation.state.localRuntime = { requestClient: { sendRequest: async (method, params) => { archiveRequests.push({ method, params }); return {}; } } };
  navigation.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), threads: [], truncated: false });
  const refreshesBeforeAbsentTask = fixture.refreshes ?? 0;
  assert.equal(await navigation.archiveTask(pathTask), false, "a task absent from fresh authoritative membership must not be archived");
  assert.equal(archiveRequests.length, 0, "the stale helper-only row must never reach thread/archive");
  assert.equal(fixture.refreshes ?? 0, refreshesBeforeAbsentTask, "a definitive pre-dispatch membership failure must not trigger a redundant device refresh");
  assert.match(navigation.state.taskActionFeedback, /Current task membership could not be confirmed/u);

  navigation.state.localRuntime = null;
  assert.equal(await navigation.archiveTask(pathTask), false, "a vanished runtime must fail visibly");
  assert.match(navigation.state.taskActionFeedback, /Archive is unavailable for this device right now/u);

  assert.equal(navigation.markPendingArchivedTask(localTask, false), true);
  const localRollbackRecord = navigation.state.pendingArchivedTasks.get(localArchiveKey);
  navigation.state.threadInventories.set("local", { error: null, fetchedAt: localRollbackRecord.requestedAt + 1, threads: [localTask], truncated: false });
  localRollbackRecord.attempts = 2;
  assert.equal(navigation.reconcilePendingArchivedTask(localArchiveKey), false, "bounded local reconciliation must restore a chat when archiving did not persist");

  const delayedTask = { ...localTask, conversationId: "33333333-3333-4333-8333-333333333333" };
  const delayedKey = navigation.pendingArchiveKey(delayedTask);
  fixture.refreshPromise = new Promise(() => {});
  assert.equal(navigation.markPendingArchivedTask(delayedTask), true);
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.equal(navigation.state.pendingArchivedTasks.has(delayedKey), false,
    "a stalled shared refresh must not extend optimistic archive suppression beyond its retry deadline");
  fixture.refreshPromise = null;

  assert.equal(navigation.markPendingArchivedTask(task, false), true);
  const omittedRecord = navigation.state.pendingArchivedTasks.get(archiveKey);
  navigation.state.threadInventories.set(hostId, {
    error: null, fetchedAt: omittedRecord.requestedAt + 1, threads: [], truncated: false,
  });
  assert.equal(navigation.reconcilePendingArchivedTask(archiveKey), false,
    "a fresh authoritative omission must confirm the archive and release temporary suppression");

  navigation.state.threadInventories.delete(hostId);
  navigation.rememberTaskActivation(task);
  const retained = new Map();
  navigation.retainRecentTaskActivations(retained);
  assert.equal(retained.has(`${hostId}::${task.conversationId}`), true,
    "a recently activated task must survive a stale inventory refresh");
  navigation.state.threadInventories.set(hostId, {
    error: null, fetchedAt: Date.now() + 1, threads: [task], truncated: false,
  });
  navigation.retainRecentTaskActivations(new Map());
  assert.equal(navigation.state.recentTaskActivations.size, 0,
    "a newer authoritative inventory must release the temporary retention");

  const pending = [{ requestId: "stale-steer", method: "turn/steer", stage: "outcome-unknown" }];
  const conversation = { threadRuntimeStatus: { type: "idle" }, unconfirmedTurnSubmissions: pending };
  const manager = {
    getConversation: () => conversation,
    updateConversationState(_id, update) { update(conversation); },
  };
  navigation.state.threadInventories.set(hostId, {
    error: null, fetchedAt: Date.now() + 1000,
    threads: [{ id: task.conversationId, status: { type: "idle" } }], truncated: false,
  });
  const recovered = await navigation.recoverUnconfirmedRemoteSteer(task, manager);
  assert.equal(recovered, 1, "a freshly confirmed idle remote steer must recover");
  assert.equal(conversation.unconfirmedTurnSubmissions, undefined, "the recovered steer marker must be removed");

  conversation.unconfirmedTurnSubmissions = [{ requestId: "uncertain-start", method: "turn/start", stage: "outcome-unknown" }];
  assert.equal(await navigation.recoverUnconfirmedRemoteSteer(task, manager), 0,
    "an uncertain turn start must never be cleared because it could duplicate work");
  assert.equal(conversation.unconfirmedTurnSubmissions.length, 1, "unsafe pending submissions must remain intact");

  conversation.unconfirmedTurnSubmissions = pending;
  navigation.state.threadInventories.set(hostId, {
    error: null, fetchedAt: Date.now() + 1000,
    threads: [{ id: task.conversationId, status: { type: "active" } }], truncated: false,
  });
  assert.equal(await navigation.recoverUnconfirmedRemoteSteer(task, manager), 0,
    "an active remote task must keep the uncertain steer marker");
  console.log("Task navigation self-test passed.");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
