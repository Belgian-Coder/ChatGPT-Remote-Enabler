"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const originalSource = fs.readFileSync(rendererPath, "utf8");
const testSource = originalSource
  .replace("(() => {", "globalThis.__visibilityTest = (() => {")
  .replace(
    "  return install();\n})();",
    "  return { collectAuthoritativeThreadIds, parseInventoryPayload, preferredThreadInventory, pruneVerifiedThreadIds, rememberVerifiedThreadIds, scopedThreadsAreFresh, serializePeerInventory, state, taskIsAuthoritative };\n})();",
  );

const now = Date.now();
const storage = new Map([
  ["codex-remote-mobile-verified-thread-ids-v1", JSON.stringify({
    local: { ids: ["v52-internal"], verifiedAt: now },
  })],
  ["codex-remote-mobile-verified-thread-ids-v2", JSON.stringify({
  expired: { contractVersion: 53, ids: ["expired"], verifiedAt: now - 8 * 24 * 60 * 60 * 1000 },
  future: { contractVersion: 53, ids: ["future"], verifiedAt: now + 10 * 60 * 1000 },
  legacyContract: { contractVersion: 52, ids: ["v52-internal"], verifiedAt: now },
  local: { contractVersion: 53, ids: ["verified-user"], verifiedAt: now },
})]]);
const context = vm.createContext({
  TextDecoder,
  TextEncoder,
  clearInterval,
  clearTimeout,
  console,
  crypto: { randomUUID: () => "visibility-test" },
  document: { querySelectorAll: () => [] },
  globalThis: null,
  localStorage: {
    getItem: (key) => storage.get(key) ?? null,
    removeItem: (key) => storage.delete(key),
    setItem: (key, value) => storage.set(key, String(value)),
  },
  setInterval,
  setTimeout,
});
context.globalThis = context;
vm.runInContext(testSource, context, { filename: rendererPath });
const visibility = context.__visibilityTest;

assert.equal(visibility.state.verifiedThreadIds.has("expired"), false);
assert.equal(visibility.state.verifiedThreadIds.has("future"), false);
assert.equal(visibility.state.verifiedThreadIds.has("legacyContract"), false);
assert.deepEqual([...visibility.state.verifiedThreadIds.get("local").ids], ["verified-user"]);

let authoritative = visibility.collectAuthoritativeThreadIds();
assert.equal(visibility.taskIsAuthoritative({ conversationId: "verified-user", hostId: "local", selected: false }, authoritative), true);
assert.equal(visibility.taskIsAuthoritative({ conversationId: "internal-child", hostId: "local", selected: true }, authoritative), false);

visibility.state.threadInventories.set("local", { error: null, threads: [] });
authoritative = visibility.collectAuthoritativeThreadIds();
assert.equal(authoritative.has("local"), true);
assert.equal(authoritative.get("local").size, 0);

visibility.state.threadInventories.set("local", { error: "temporary failure", threads: [{ id: "internal-child" }] });
authoritative = visibility.collectAuthoritativeThreadIds();
assert.deepEqual([...authoritative.get("local")], ["verified-user"]);

visibility.state.threadInventories.clear();
visibility.state.verifiedThreadIds.clear();
const hostId = "peer-host";
visibility.state.verifiedThreadIds.set(hostId, { ids: new Set(["peer-user", "archived-peer-task"]), verifiedAt: now });
visibility.state.remoteProjectInventories.set(hostId, {
  error: null,
  fetchedAt: now,
  generatedAt: now,
  projects: [],
  projectsAuthoritative: true,
  publisherVersion: 53,
  sourcePeerCache: true,
  threadScope: "user-visible",
  threadScopeGeneratedAt: now,
  threads: [{ id: "peer-user" }],
  threadsAuthoritative: true,
});
authoritative = visibility.collectAuthoritativeThreadIds();
assert.deepEqual([...authoritative.get(hostId)], ["peer-user"]);
assert.equal(visibility.taskIsAuthoritative({ conversationId: "archived-peer-task", hostId }, authoritative), false);

visibility.state.remoteProjectInventories.set(hostId, {
  ...visibility.state.remoteProjectInventories.get(hostId),
  threads: [],
});
authoritative = visibility.collectAuthoritativeThreadIds();
assert.equal(authoritative.has(hostId), true);
assert.equal(authoritative.get(hostId).size, 0);

visibility.state.threadInventories.set(hostId, { error: null, threads: [{ id: "direct-user" }] });
authoritative = visibility.collectAuthoritativeThreadIds();
assert.deepEqual([...authoritative.get(hostId)], ["direct-user"]);
visibility.state.threadInventories.clear();

visibility.state.remoteProjectInventories.set(hostId, {
  error: null,
  fetchedAt: now,
  generatedAt: now,
  projects: [],
  projectsAuthoritative: true,
  sourcePeerCache: true,
  threadScope: null,
  threads: [{ id: "legacy-internal" }],
  threadsAuthoritative: true,
});
authoritative = visibility.collectAuthoritativeThreadIds();
assert.deepEqual([...authoritative.get(hostId)], ["peer-user", "archived-peer-task"]);

const scoped = {
  generatedAt: now - 1000,
  hostDisplayName: "PC-Marc",
  publisherVersion: 53,
  threadScope: "user-visible",
  threadScopeGeneratedAt: now - 1000,
  threads: [{ id: "safe" }],
  threadsAuthoritative: true,
};
const legacy = { generatedAt: now, threadScope: null, threads: [{ id: "internal" }], threadsAuthoritative: true };
assert.equal(visibility.preferredThreadInventory(scoped, legacy), scoped);
assert.equal(visibility.preferredThreadInventory(scoped, { ...scoped, generatedAt: now, publisherVersion: 52 }), scoped);
assert.equal(visibility.scopedThreadsAreFresh(scoped), true);
assert.equal(visibility.scopedThreadsAreFresh({ ...scoped, threadScopeGeneratedAt: now - 181000 }), false);
assert.equal(visibility.scopedThreadsAreFresh({ ...scoped, publisherVersion: 52 }), false);

const relayed = visibility.serializePeerInventory(scoped);
assert.equal(Date.parse(relayed.threadScopeGeneratedAt), scoped.threadScopeGeneratedAt);
assert.equal(relayed.hostDisplayName, "PC-Marc");
const roundTripped = visibility.parseInventoryPayload({
  ...relayed,
  projects: [],
  schemaVersion: 1,
  tasks: [],
}, false);
assert.equal(roundTripped.threadScopeGeneratedAt, scoped.threadScopeGeneratedAt);
assert.equal(roundTripped.hostDisplayName, "PC-Marc");
assert.equal(visibility.scopedThreadsAreFresh(roundTripped), true);

const syntheticName = visibility.parseInventoryPayload({
  ...relayed,
  hostDisplayName: "Remote env_e_deadbeef",
  projects: [],
  schemaVersion: 1,
  tasks: [],
}, false);
assert.equal(syntheticName.hostDisplayName, null);

assert.match(originalSource, /USER_VISIBLE_THREAD_SOURCE_KINDS = Object\.freeze\(\["cli", "vscode"\]\)/);
assert.doesNotMatch(originalSource, /!authoritativeIds\.has\(task\.hostId\) && !task\.selected/);
assert.match(originalSource, /threadScopeGeneratedAt/);

console.log("Thread visibility self-test passed.");
