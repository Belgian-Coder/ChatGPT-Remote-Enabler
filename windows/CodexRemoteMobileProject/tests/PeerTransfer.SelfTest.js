"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const filename = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const original = fs.readFileSync(filename, "utf8").replace(/\r\n/g, "\n");
const source = original.replace("  return install();\n})();", "  globalThis.transportFixture = { state, compactInventoryText, peerTransferText, peerContentSignature, inventoryHasWork, parseInventoryPayload, queuePeerTransfer, drainPeerTransfer, resolveRemoteHome, scheduleRemoteProjectInventory, connectionGuidance, peerWriteLocks };\n})();");
assert.notEqual(original, source);
let now = Date.now();
let timerId = 0;
const timers = new Map();
class Clock extends Date { constructor(...args) { super(...(args.length ? args : [now])); } static now() { return now; } }
const context = vm.createContext({ Date: Clock, console, TextEncoder, TextDecoder, atob, btoa,
  setTimeout: (fn, delay) => { const id = ++timerId; timers.set(id, { fn, at: now + delay }); return id; },
  clearTimeout: id => timers.delete(id), setInterval: () => 1, clearInterval() {},
  requestAnimationFrame: () => 1, cancelAnimationFrame() {},
  document: { querySelectorAll: () => [], querySelector: () => null, getElementById: () => null },
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  crypto: { randomUUID: () => "transport-fixture" },
});
vm.runInContext(source, context, { filename });
let t = context.transportFixture;
const host = "remote-control:" + "env" + "_transport_peer";
const other = "remote-control:" + "env" + "_transport_third";
const snapshot = title => ({ schemaVersion: 1, publisherVersion: 53, generatedAt: new Date(now).toISOString(), helperVersion: "v1.5.35", hostDisplayName: "Fixture peer", projects: [{ name: "Fixture project", rootPaths: ["/fixture/project"] }], tasks: [{ conversationKey: "fixture-task", statusType: "idle", unread: false }], threadScope: "user-visible", threadScopeGeneratedAt: new Date(now).toISOString(), threads: [{ id: "fixture-task", cwd: "/fixture/project", title, titleSource: "app-server-title", projectId: null, workspaceKind: null, updatedAt: null, hasUnreadTurn: false, status: "idle" }], peers: {} });
const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
async function advance(ms) { now += ms; for (let i = 0; i < 30; i++) { const due = [...timers].filter(([,v]) => v.at <= now); if (!due.length) break; for (const [id, v] of due) { timers.delete(id); v.fn(); } await flush(); } }
(async () => {
  const originalPayload = snapshot("Unicode task ✨");
  const compact = JSON.parse(t.compactInventoryText(originalPayload));
  assert.deepEqual(JSON.parse(JSON.stringify(t.parseInventoryPayload(compact))), JSON.parse(JSON.stringify(t.parseInventoryPayload(originalPayload))), "nullable-field removal must preserve all parsed semantics");
  const payload = { ...originalPayload, peers: { [host]: snapshot("Receiver copy"), [other]: snapshot("Third peer") } };
  const sent = JSON.parse(t.peerTransferText(payload, host));
  assert.equal(sent.peers[host], undefined);
  assert.equal(sent.peers[other].threads[0].title, "Third peer");
  assert.equal(t.peerContentSignature({ [host]: originalPayload }), t.peerContentSignature({ [host]: { ...originalPayload, generatedAt: new Date(now + 5000).toISOString(), threadScopeGeneratedAt: new Date(now + 5000).toISOString() } }));
  assert.notEqual(t.peerContentSignature({ [host]: originalPayload }), t.peerContentSignature({ [host]: snapshot("Changed title") }));
  assert.equal(t.inventoryHasWork(originalPayload.tasks, originalPayload.threads), false);
  assert.equal(t.inventoryHasWork([{ statusType: "loading" }]), true);
  assert.equal(t.inventoryHasWork([], [{ status: "inProgress" }]), true);

  const writes = []; let finish; let active = 0; let maxActive = 0; let configReads = 0;
  const runtime = { requestClient: { sendRequest: async (method, params) => {
    if (method === "config/read") { configReads++; return { home: "/fixture/.codex" }; }
    assert.equal(method, "fs/writeFile"); active++; maxActive = Math.max(maxActive, active); writes.push(JSON.parse(Buffer.from(params.dataBase64, "base64").toString("utf8")));
    await new Promise(resolve => { finish = resolve; }); active--; return {};
  } } };
  t.queuePeerTransfer(host, runtime, snapshot("first")); await flush();
  t.queuePeerTransfer(host, runtime, snapshot("discard intermediate"));
  t.queuePeerTransfer(host, runtime, snapshot("newest")); await flush();
  assert.equal(writes.length, 1);
  finish(); await flush(); await advance(1000);
  assert.equal(writes.length, 2); assert.equal(writes[1].threads[0].title, "newest"); assert.equal(maxActive, 1);
  finish(); await flush(); assert.equal(configReads, 1);
  // A timed-out native RPC remains locked, including across reinjection state.
  t.queuePeerTransfer(host, runtime, snapshot("slow")); await flush();
  const slowFinish = finish; await advance(12000);
  assert.equal(t.state.peerTransfers.get(host).error, "timeout"); assert.equal(t.peerWriteLocks.has(host), true);
  t.queuePeerTransfer(host, runtime, snapshot("after timeout")); await advance(60000);
  assert.equal(writes.length, 3, "a timeout must not permit a concurrent native write");
  const lockBefore = t.peerWriteLocks;
  vm.runInContext(source, context, { filename });
  assert.equal(context.transportFixture.peerWriteLocks, lockBefore, "reinjection must retain unresolved write ownership");
  t = context.transportFixture; t.queuePeerTransfer(host, runtime, snapshot("after timeout")); await flush(); assert.equal(writes.length, 3);
  slowFinish(); await flush(); await advance(1000);
  assert.equal(writes.at(-1).threads[0].title, "after timeout"); finish(); await flush(); assert.equal(maxActive, 1);
  const failHost = host + "failure"; let attempts = 0;
  const failing = { requestClient: { sendRequest: async method => { if (method === "config/read") return { home: "/fixture/.codex" }; attempts++; throw new Error("fixture rejection"); } } };
  t.queuePeerTransfer(failHost, failing, snapshot("retry")); await flush(); assert.equal(attempts, 1);
  await advance(1999); assert.equal(attempts, 1);
  await advance(1); assert.equal(attempts, 2);
  await advance(3999); assert.equal(attempts, 2);
  await advance(1); assert.equal(attempts, 3);
  // Expired jobs are never retried, and disposal cannot launch queued work.
  const failed = t.state.peerTransfers.get(failHost); now += 181000; await t.drainPeerTransfer(failHost, failed); assert.equal(attempts, 3);
  t.state.disposed = true; t.queuePeerTransfer(failHost, failing, snapshot("disposed")); assert.equal(attempts, 3); t.state.disposed = false;

  const readHost = host + "read";
  let finishConfig, discoveryCalls = 0, readCalls = 0;
  const readRuntime = { requestClient: { sendRequest: async method => {
    if (method === "config/read") { discoveryCalls++; return await new Promise(resolve => { finishConfig = resolve; }); }
    if (method === "fs/readFile") { readCalls++; return { dataBase64: Buffer.from(t.compactInventoryText(snapshot("direct read"))).toString("base64") }; }
    if (method === "fs/writeFile") return {};
    throw new Error("Unexpected request");
  } } };
  t.scheduleRemoteProjectInventory(new Map([[readHost, readRuntime]]));
  t.queuePeerTransfer(readHost, readRuntime, snapshot("simultaneous push"));
  await flush(); assert.equal(discoveryCalls, 1, "simultaneous pull/push must share configuration discovery");
  finishConfig({ home: "/fixture/.codex" }); await flush();
  assert.equal(readCalls, 1); assert.equal(t.state.remoteProjectInventories.get(readHost).threads[0].title, "direct read");
  const acquired = t.state.remoteProjectInventories.get(readHost).fetchedAt;
  t.scheduleRemoteProjectInventory(new Map([[readHost, readRuntime]])); await flush(); assert.equal(readCalls, 1);
  readRuntime.requestClient.sendRequest = async () => { throw new Error("Disconnected fixture"); };
  now += 5001;
  t.scheduleRemoteProjectInventory(new Map([[readHost, readRuntime]]), true); await flush();
  assert.equal(t.state.remoteProjectInventories.get(readHost).fetchedAt, acquired, "failed transfer cannot renew inventory authority");
  assert.ok(t.state.remoteProjectInventories.get(readHost).error);

  const remoteHost = { id: host, availabilityKnown: false };
  t.state.hostConnectivity.clear(); t.state.remoteProjectInventories.clear();
  assert.equal(t.connectionGuidance(remoteHost).code, "unknown");
  assert.equal(t.connectionGuidance({ ...remoteHost, availabilityKnown: true, available: false }).code, "disconnected");
  t.state.hostConnectivity.set(host, { available: true, checkedAt: now });
  assert.equal(t.connectionGuidance(remoteHost).code, "publisher-unavailable");
  const fresh = t.parseInventoryPayload(snapshot("healthy"));
  t.state.remoteProjectInventories.set(host, { ...fresh, fetchedAt: now });
  t.state.peerTransfers.delete(host);
  assert.equal(t.connectionGuidance(remoteHost).code, "healthy");
  t.state.remoteProjectInventories.get(host).threadScopeGeneratedAt = now - 181000;
  assert.equal(t.connectionGuidance(remoteHost).code, "stale", "new heartbeats must not mask stale membership");
  t.state.remoteProjectInventories.set(host, { ...fresh, fetchedAt: now, sourcePeerCache: true });
  assert.equal(t.connectionGuidance(remoteHost).code, "cached");

  const large = snapshot("benchmark");
  large.threads = Array.from({ length: 1000 }, (_, i) => ({ ...large.threads[0], id: `task-${i}`, title: `Fixture task ${i}` }));
  const twoClient = { ...large, peers: { [host]: large } };
  const oldBytes = Buffer.byteLength(JSON.stringify(twoClient)); const newBytes = Buffer.byteLength(t.peerTransferText(twoClient, host));
  assert.ok(newBytes < oldBytes * .55);
  console.log(JSON.stringify({ nullableSemanticsPreserved: true, recipientEchoRemoved: true, thirdPeerRetained: true, timestampEchoSuppressed: true, idleTaskDetection: true, latestSnapshotCoalesced: true, maxConcurrentWrites: maxActive, timeoutLockAcrossReinjection: true, exponentialRetry: true, expiredAndDisposedJobsSkipped: true, sharedPullPushDiscovery: true, failedReadPreservesAuthority: true, connectionFindings: 6, fixtureThreadsPerClient: 1000, previousPushJsonBytes: oldBytes, optimizedPushJsonBytes: newBytes, pushReductionPercent: Math.round(100 * (1 - newBytes / oldBytes)) }));
})().catch(error => { console.error(error); process.exitCode = 1; });
