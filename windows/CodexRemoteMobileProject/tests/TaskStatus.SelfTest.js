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
    "  return { applyRemoteTaskState, publishedTaskMetadata, remoteTaskStatusIsFresh };\n})();",
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

const loadingState = { statusKnown: true, statusType: "loading", unreadKnown: true, unread: false };
const inventory = {
  generatedAt: now,
  tasks: new Map([["thread-1", loadingState]]),
};

const directCompleted = {
  conversationId: "thread-1",
  conversationKey: "thread-1",
  directStatusKnown: true,
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

const remoteThreadCompleted = { ...fallbackTask, statusType: "idle", threadStatusKnown: true };
status.applyRemoteTaskState(remoteThreadCompleted, inventory, now);
assert.equal(remoteThreadCompleted.statusType, "idle", "remote app-server thread status must outrank its DOM task snapshot");

const staleTask = { ...fallbackTask, statusType: "idle" };
status.applyRemoteTaskState(staleTask, { ...inventory, generatedAt: now - 30001 }, now);
assert.equal(staleTask.statusType, "idle", "an orphaned loading snapshot must expire");
assert.equal(status.remoteTaskStatusIsFresh({ generatedAt: now + 5 * 60 * 1000 + 1 }, loadingState, now), false);

const domTask = { conversationId: "thread-1", conversationKey: "thread-1", statusType: "loading", unread: true };
const publishedCompleted = status.publishedTaskMetadata(domTask, { id: "thread-1", status: { type: "notLoaded" }, hasUnreadTurn: false });
assert.equal(publishedCompleted.conversationKey, "thread-1");
assert.equal(publishedCompleted.statusType, "idle", "publisher must replace stale DOM state with app-server completion state");
assert.equal(publishedCompleted.unread, false);
assert.equal(status.publishedTaskMetadata(domTask, { id: "thread-1", status: { type: "active" } }).statusType, "loading");

console.log("Task status self-test passed.");
