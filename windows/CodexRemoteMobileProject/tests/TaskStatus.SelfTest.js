"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const originalSource = fs.readFileSync(rendererPath, "utf8");
const testSource = originalSource
  .replace("(() => {", "globalThis.__taskStatusTest = (() => {")
  .replace(
    "  return install();\n})();",
    "  return { applyRemoteTaskState, parseInventoryPayload, publishedTaskMetadata, remoteTaskStatusIsFresh, serializePeerInventory };\n})();",
  );

const context = vm.createContext({
  TextDecoder,
  TextEncoder,
  clearInterval,
  clearTimeout,
  console,
  crypto: { randomUUID: () => "task-status-test" },
  document: { querySelectorAll: () => [] },
  globalThis: null,
  localStorage: {
    getItem: () => null,
    removeItem: () => {},
    setItem: () => {},
  },
  setInterval,
  setTimeout,
});
context.globalThis = context;
vm.runInContext(testSource, context, { filename: rendererPath });
const status = context.__taskStatusTest;
const now = Date.now();

const loadingState = { activeFlags: ["waitingOnApproval"], statusKnown: true, statusObservedAt: now - 10, statusType: "loading", unreadKnown: true, unread: false };
const inventory = {
  generatedAt: now,
  tasks: new Map([["thread-1", loadingState]]),
};

const directCompleted = {
  conversationId: "thread-1",
  conversationKey: "thread-1",
  directStatusKnown: true,
  statusKnown: true,
  statusObservedAt: now,
  threadStatusKnown: true,
  statusType: "idle",
  unread: false,
};
status.applyRemoteTaskState(directCompleted, inventory, now);
assert.equal(directCompleted.statusType, "idle", "direct completed app-server status must outrank a peer loading snapshot");

const fallbackTask = {
  conversationId: "thread-1",
  conversationKey: "thread-1",
  directStatusKnown: false,
  threadStatusKnown: false,
  statusType: "idle",
  unread: false,
};
status.applyRemoteTaskState(fallbackTask, inventory, now);
assert.equal(fallbackTask.statusType, "loading", "a fresh peer loading snapshot remains a valid fallback");
assert.equal(fallbackTask.statusKnown, true, "accepted peer task status must retain its authority marker");
assert.equal(fallbackTask.unreadKnown, true, "accepted peer unread state must retain its authority marker");

const remoteThreadCompleted = { ...fallbackTask, statusType: "idle", threadStatusKnown: true };
remoteThreadCompleted.statusKnown = true;
remoteThreadCompleted.statusObservedAt = now;
status.applyRemoteTaskState(remoteThreadCompleted, inventory, now);
assert.equal(remoteThreadCompleted.statusType, "idle", "remote app-server thread status must outrank its DOM task snapshot");

const staleTask = { ...fallbackTask, statusType: "idle" };
const staleLoading = { ...loadingState, statusObservedAt: now - 30001 };
status.applyRemoteTaskState(staleTask, { ...inventory, generatedAt: now, tasks: new Map([["thread-1", staleLoading]]) }, now);
assert.equal(staleTask.statusType, "idle", "an orphaned loading snapshot must expire");
assert.equal(status.remoteTaskStatusIsFresh({ generatedAt: now + 5 * 60 * 1000 + 1 }, loadingState, now), false);
assert.equal(status.remoteTaskStatusIsFresh({ generatedAt: now }, staleLoading, now), false,
  "a new inventory heartbeat must not renew an old loading observation");

const domTask = { conversationId: "thread-1", conversationKey: "thread-1", originalRow: {}, statusObservedAt: 0, statusType: "loading", unread: true };
const publishedCompleted = status.publishedTaskMetadata(domTask, { id: "thread-1", status: { type: "notLoaded" }, hasUnreadTurn: false }, now);
assert.equal(publishedCompleted.conversationKey, "thread-1");
assert.equal(publishedCompleted.statusType, "idle", "a cold-start stale DOM spinner must not outrank app-server completion");
assert.equal(publishedCompleted.unread, false);
const changedDom = { ...domTask, attentionKind: "input", statusObservedAt: now + 1 };
const publishedLive = status.publishedTaskMetadata(changedDom, { id: "thread-1", status: { type: "notLoaded" }, hasUnreadTurn: false }, now);
assert.equal(publishedLive.statusType, "loading", "a genuinely newer native status must outrank the membership snapshot");
assert.deepEqual([...publishedLive.activeFlags], ["waitingOnUserInput"], "attention flags must survive publication");
assert.equal(status.publishedTaskMetadata(domTask, { id: "thread-1", status: { type: "active" } }, now).statusType, "loading");

const parsed = status.parseInventoryPayload({
  generatedAt: new Date(now).toISOString(), projects: [], publisherVersion: 53, schemaVersion: 1,
  tasks: [{ activeFlags: ["waitingOnApproval"], conversationKey: "thread-1", statusObservedAt: now - 10, statusType: "loading", unread: true }],
  threadScope: "user-visible", threadScopeGeneratedAt: new Date(now - 20).toISOString(), threads: [],
});
assert.deepEqual([...parsed.tasks.get("thread-1").activeFlags], ["waitingOnApproval"]);
assert.equal(parsed.tasks.get("thread-1").statusObservedAt, now - 10);
const relayed = status.serializePeerInventory(parsed);
assert.deepEqual([...relayed.tasks[0].activeFlags], ["waitingOnApproval"], "peer relay must preserve bounded attention flags");
assert.equal(relayed.tasks[0].statusObservedAt, now - 10, "peer relay must preserve status observation time");

console.log("Task status self-test passed.");
