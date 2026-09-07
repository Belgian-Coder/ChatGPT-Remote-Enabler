"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const originalSource = fs.readFileSync(rendererPath, "utf8");
const testSource = originalSource
  .replace("(() => {", "globalThis.__navigationTest = (() => {")
  .replace(/  return install\(\);\r?\n\}\)\(\);\s*$/u, `  return {
    state, openNativeTask, recoverUnconfirmedRemoteSteer, rememberTaskActivation, retainRecentTaskActivations,
    configure(fixture) {
      confirmRemoteTaskMembership = async () => fixture.membership !== false;
      nativeNavigationDispatcher = () => fixture.navigate;
      refreshLocalRegisteredProjects = async () => state.localRegisteredProjects;
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
      requestDeviceRefresh = async () => fixture.refreshResult ?? { complete: true };
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
  const reopened = await navigation.openNativeTask(task, registeredProject);
  assert.equal(reopened, true, "a synthetic task in an existing remote project must hydrate and open");
  assert.equal(fixture.registrations, 0, "an existing remote project must not be registered again");
  assert.equal(nativeRow.clicks, 1, "expanding the native project must expose and invoke the task row");

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
