"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const original = fs.readFileSync(rendererPath, "utf8");
const source = original.replace("  return install();\n})();", "  globalThis.features = { state, hostName, displayDeviceName, saveDeviceAlias, parseInventoryPayload, serializePeerInventory, previewAutoArchive, requestCleanupPreview, readCleanupHistory, recordCleanupEvent, runAutoArchiveNow, diagnosticSnapshot, normalizeUpdateDetails };\n})();");
assert.notEqual(source, original);
const storage = new Map();
const context = vm.createContext({
  console, TextEncoder, TextDecoder,
  setTimeout: (...args) => { const timer = setTimeout(...args); timer.unref(); return timer; }, clearTimeout,
  setInterval: (...args) => { const timer = setInterval(...args); timer.unref(); return timer; }, clearInterval,
  requestAnimationFrame: () => 1, cancelAnimationFrame() {},
  crypto: { randomUUID: () => "feature-fixture" },
  navigator: { locks: { request: async (name, options, callback) => callback({ name }) } },
  document: { querySelectorAll: () => [], getElementById: () => null },
  localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) },
});
vm.runInContext(source, context, { filename: rendererPath });
const f = context.features;
const now = Date.now(), old = now - 9 * 86400000;
const hostId = "remote-control:" + "env" + "_feature_fixture";
f.state.displayedHosts = [{ id: hostId, name: "Reported device" }];
assert.equal(f.saveDeviceAlias(hostId, "Desk alias"), true);
assert.equal(f.displayDeviceName(hostId, "Reported device"), "Desk alias");
assert.equal(f.hostName(hostId, new Map([[hostId, "Reported device"]]), null), "Reported device");
assert.equal(JSON.parse(storage.get("codex-remote-mobile-host-names-v1"))[hostId], "Reported device");
assert.equal(f.saveDeviceAlias(hostId, "x".repeat(61)), false);
assert.equal(f.saveDeviceAlias(hostId, "bad\nname"), false);
assert.equal(f.saveDeviceAlias("unrecognized-host", "Alias"), false);
assert.equal(f.saveDeviceAlias(hostId, ""), true);
assert.equal(f.displayDeviceName(hostId, "Reported device"), "Reported device");
const payload = { schemaVersion: 1, publisherVersion: 53, generatedAt: new Date().toISOString(), helperVersion: "v1.5.34", projects: [], tasks: [], threads: [] };
assert.equal(f.parseInventoryPayload(payload).helperVersion, "v1.5.34");
assert.equal(f.parseInventoryPayload({ ...payload, helperVersion: "file:///private" }).helperVersion, null);
assert.equal(f.serializePeerInventory(f.parseInventoryPayload(payload)).helperVersion, "v1.5.34");

let active = [
  { id: "archive-me", title: "Archive candidate", status: "notLoaded", updatedAt: old, path: "/fixture/.codex/sessions/a.jsonl" },
  { id: "pinned", title: "Pinned task", status: "notLoaded", updatedAt: old, path: "/fixture/.codex/sessions/p.jsonl" },
  { id: "working", title: "Working task", status: "active", updatedAt: old, path: "/fixture/.codex/sessions/w.jsonl" },
];
let archived = [{ id: "delete-me", title: "Delete candidate", status: "notLoaded", updatedAt: old, path: "/fixture/.codex/archived_sessions/d.jsonl" }];
const mutations = [];
let listCalls = 0;
f.state.localCodexHome = "/fixture/.codex";
f.state.localFetchFromHost = async () => ({ value: ["pinned"] });
f.state.localRuntime = { requestClient: {
  async sendRequest(method, params) {
    if (method === "thread/list") { listCalls += 1; return { data: params.archived ? archived : active, nextCursor: null }; }
    mutations.push(method);
    if (method === "thread/archive") {
      const thread = active.find(item => item.id === params.threadId);
      active = active.filter(item => item.id !== params.threadId);
      archived.push({ ...thread, path: "/fixture/.codex/archived_sessions/a.jsonl" });
    }
    if (method === "thread/delete") archived = archived.filter(item => item.id !== params.threadId);
    return {};
  },
} };
storage.set("codex-remote-mobile-auto-archived-records-v1", JSON.stringify({ "delete-me": old }));

(async () => {
  const beforeStorage = [...storage];
  const preview = await f.previewAutoArchive();
  assert.equal(preview.archiveEligible, 1);
  assert.equal(preview.deleteEligible, 1);
  assert.equal(preview.archiveCandidates[0].title, "Archive candidate");
  assert.equal(preview.deleteCandidates[0].title, "Delete candidate");
  assert.ok(preview.exclusions.some(item => item.reason === "Pinned tasks" && item.count === 1));
  assert.deepEqual(mutations, [], "preview must never issue archive/delete commands");
  assert.deepEqual([...storage], beforeStorage, "preview must not enable cleanup or change recovery tracking");
  const beforeLists = listCalls;
  const first = f.requestCleanupPreview();
  assert.equal(f.requestCleanupPreview(), first, "concurrent preview requests must share one scan");
  await first;
  assert.equal(listCalls - beforeLists, 2);
  f.state.localFetchFromHost = async () => { throw new Error("Pin data unavailable"); };
  await assert.rejects(f.previewAutoArchive(), /Pin data unavailable/);
  assert.deepEqual(mutations, []);
  f.state.localFetchFromHost = async () => ({ value: ["pinned"] });
  storage.set("codex-remote-mobile-auto-archive-enabled-v1", "true");
  await f.runAutoArchiveNow();
  await f.runAutoArchiveNow();
  assert.deepEqual(mutations.sort(), ["thread/archive", "thread/delete"]);
  const history = f.readCleanupHistory();
  assert.equal(history.length, 2);
  assert.ok(history.some(item => item.action === "archived" && item.title === "Archive candidate"));
  assert.ok(history.some(item => item.action === "deleted" && item.title === "Delete candidate"));
  for (let index = 0; index < 105; index++) f.recordCleanupEvent("incomplete");
  assert.equal(f.readCleanupHistory().length, 100);
  storage.set("codex-remote-mobile-cleanup-history-v1", JSON.stringify([{ at: now - 100 * 86400000, action: "archived", title: "expired" }]));
  assert.equal(f.readCleanupHistory().length, 0);
  storage.set("codex-remote-mobile-cleanup-history-v1", "invalid json");
  assert.equal(f.readCleanupHistory().length, 0);
  assert.equal(f.state.cleanupHistoryUnavailable, true);
  f.state.remoteProjectInventories.set(hostId, { error: "credential=private-secret", helperVersion: "v1.5.34", generatedAt: now });
  const snapshot = JSON.stringify(f.diagnosticSnapshot({ hosts: [{ id: hostId, name: "private-device", availabilityKnown: true, available: false }], projects: [{ hostId, name: "private-project", cwd: "/private/path" }], tasks: [{ hostId, title: "private-title" }] }));
  assert.doesNotMatch(snapshot, /private|feature_fixture|credential|remote-control/);
  assert.match(snapshot, /Device 1/);
  assert.equal(f.normalizeUpdateDetails({ installedVersion: "javascript:secret", history: [{ state: "made-up", at: now }] }).installedVersion, null);
  console.log(JSON.stringify({ aliasesSeparateFromIdentity: true, helperVersionRoundtrip: true, previewReadOnly: true, previewSingleflight: true, missingPinsFailClosed: true, actualCleanupHistory: true, boundedHistory: true, diagnosticsAllowlist: true }));
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  f.state.disposed = true;
  if (f.state.autoArchiveTimer) clearTimeout(f.state.autoArchiveTimer);
  if (f.state.autoArchiveLeaseTimer) clearInterval(f.state.autoArchiveLeaseTimer);
});
