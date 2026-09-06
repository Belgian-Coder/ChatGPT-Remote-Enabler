"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const original = fs.readFileSync(rendererPath, "utf8");
const source = original.replace("  return install();\n})();", "  globalThis.features = { state, hostName, displayDeviceName, saveDeviceAlias, compareDeviceAliasRecords, deviceAliasesForDestination, mergeDeviceAliasRecords, mergeInventoryDeviceAliases, parseDeviceAliasEnvelope, parseInventoryPayload, peerTransferText, publicationSignature, publishedDeviceAliases, readDeviceAliasRecords, serializePeerInventory, previewAutoArchive, requestCleanupPreview, readCleanupHistory, recordCleanupEvent, runAutoArchiveNow, diagnosticSnapshot, normalizeUpdateDetails };\n})();");
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
assert.equal(f.readDeviceAliasRecords()[hostId].value, null, "reset must retain a shared tombstone");
assert.match(f.state.aliasFeedback.get(hostId), /Sharing is queued/u);
const payload = { schemaVersion: 1, publisherVersion: 53, generatedAt: new Date().toISOString(), helperVersion: "v1.5.34", projects: [], tasks: [], threads: [] };
assert.equal(f.parseInventoryPayload(payload).helperVersion, "v1.5.34");
assert.equal(f.parseInventoryPayload({ ...payload, helperVersion: "file:///private" }).helperVersion, null);
assert.equal(f.serializePeerInventory(f.parseInventoryPayload(payload)).helperVersion, "v1.5.34");

function aliasClient(name, knownIds, initialStorage = []) {
  const values = new Map(initialStorage);
  const clock = { now: Date.now() };
  class ClientDate extends Date {
    constructor(...args) { super(...(args.length ? args : [clock.now])); }
    static now() { return clock.now; }
  }
  const clientContext = vm.createContext({
    Date: ClientDate, console, TextEncoder, TextDecoder,
    setTimeout: () => 1, clearTimeout() {}, setInterval: () => 1, clearInterval() {},
    requestAnimationFrame: () => 1, cancelAnimationFrame() {},
    crypto: { randomUUID: () => name },
    document: { querySelectorAll: () => [], getElementById: () => null },
    localStorage: { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, String(value)), removeItem: key => values.delete(key) },
  });
  vm.runInContext(source, clientContext, { filename: rendererPath });
  clientContext.features.state.displayedHosts = [{ id: "local", name: name }, ...knownIds.map(id => ({ id, name: id }))];
  return { clock, f: clientContext.features, storage: values };
}

const aliasEnvironmentPrefix = "remote-control:" + "env" + "_";
const aliasA = `${aliasEnvironmentPrefix}alias_a`;
const aliasB = `${aliasEnvironmentPrefix}alias_b`;
const aliasC = `${aliasEnvironmentPrefix}alias_c`;
const clientA = aliasClient("alias-a", [aliasB, aliasC]);
const clientB = aliasClient("alias-b", [aliasA, aliasC]);
const clientC = aliasClient("alias-c", [aliasA, aliasB]);
const deliver = (from, to, sourceId, recipientId) => {
  const outgoing = {
    schemaVersion: 1,
    publisherVersion: 53,
    generatedAt: new Date(from.clock.now).toISOString(),
    projects: [], tasks: [], threads: [], peers: {},
    deviceAliases: from.f.publishedDeviceAliases(),
  };
  const received = to.f.parseInventoryPayload(JSON.parse(from.f.peerTransferText(outgoing, recipientId)));
  return to.f.mergeInventoryDeviceAliases(received.deviceAliases, sourceId, true);
};

assert.equal(clientA.f.saveDeviceAlias(aliasB, "Beta desk"), true);
assert.equal(deliver(clientA, clientB, aliasA, aliasB), true, "recipient alias must map to the authenticated receiver-local identity");
assert.equal(deliver(clientA, clientC, aliasA, aliasC), true, "a known third device alias must retain its stable environment identity");
assert.equal(clientB.f.displayDeviceName("local", "Beta verified"), "Beta desk");
assert.equal(clientC.f.displayDeviceName(aliasB, "Beta verified"), "Beta desk");
const betaUnchanged = clientB.storage.get("codex-remote-mobile-device-alias-records-v2");
assert.equal(deliver(clientA, clientB, aliasA, aliasB), false, "repeated delivery must be a semantic no-op");
assert.equal(clientB.storage.get("codex-remote-mobile-device-alias-records-v2"), betaUnchanged, "an echo must not rewrite storage or advance a clock");

clientB.clock.now += 10;
assert.equal(clientB.f.saveDeviceAlias("local", "Beta studio"), true);
assert.equal(deliver(clientB, clientA, aliasB, aliasA), true);
assert.equal(deliver(clientB, clientC, aliasB, aliasC), true);
assert.equal(clientA.f.displayDeviceName(aliasB, "Beta verified"), "Beta studio");
assert.equal(clientC.f.displayDeviceName(aliasB, "Beta verified"), "Beta studio");

clientC.clock.now += 20;
assert.equal(clientC.f.saveDeviceAlias(aliasB, ""), true);
assert.equal(deliver(clientC, clientA, aliasC, aliasA), true);
assert.equal(clientA.f.displayDeviceName(aliasB, "Beta verified"), "Beta verified");
assert.equal(clientB.f.displayDeviceName("local", "Beta verified"), "Beta studio", "an offline client must retain its last local record until reconnect");
assert.equal(deliver(clientC, clientB, aliasC, aliasB), true, "the queued reset must apply after reconnect");
assert.equal(clientB.f.displayDeviceName("local", "Beta verified"), "Beta verified");
assert.equal(clientC.f.readDeviceAliasRecords()[aliasB].value, null);
assert.equal(clientA.f.readDeviceAliasRecords()[aliasB].value, null);
assert.equal(clientB.f.readDeviceAliasRecords().local.value, null);
const stableSignature = clientA.f.publicationSignature({}, [], [], [], 1, clientA.f.publishedDeviceAliases());
assert.equal(clientA.f.publicationSignature({}, [], [], [], 1, clientA.f.publishedDeviceAliases()), stableSignature, "unchanged aliases must not create publication churn");

const collisionClient = aliasClient("alias-collision", [aliasA]);
const older = { schemaVersion: 1, updatedAt: collisionClient.clock.now - 1, value: "Older", writerId: "peer" };
const newer = { schemaVersion: 1, updatedAt: collisionClient.clock.now, value: "Newer", writerId: "peer" };
assert.equal(collisionClient.f.mergeInventoryDeviceAliases({ schemaVersion: 1, selfAlias: newer, records: { [aliasA]: older } }, aliasA), true);
assert.equal(collisionClient.f.displayDeviceName(aliasA, "Verified"), "Newer", "selfAlias and same-host records must be resolved by LWW comparison");
assert.ok(collisionClient.f.compareDeviceAliasRecords({ ...newer, value: "ä" }, { ...newer, value: "z" }) > 0, "tie ordering must be locale independent");

const orderLeft = aliasClient("alias-order-left", [aliasA, aliasB, aliasC]);
const orderRight = aliasClient("alias-order-right", [aliasA, aliasB, aliasC]);
const equalClockA = { schemaVersion: 1, updatedAt: orderLeft.clock.now, value: "Writer A", writerId: "writer-a" };
const equalClockB = { schemaVersion: 1, updatedAt: orderLeft.clock.now, value: "Writer B", writerId: "writer-b" };
const envelopeFor = record => ({ schemaVersion: 1, records: { [aliasB]: record } });
orderLeft.f.mergeInventoryDeviceAliases(envelopeFor(equalClockA), aliasA);
orderLeft.f.mergeInventoryDeviceAliases(envelopeFor(equalClockB), aliasC);
orderRight.f.mergeInventoryDeviceAliases(envelopeFor(equalClockB), aliasC);
orderRight.f.mergeInventoryDeviceAliases(envelopeFor(equalClockA), aliasA);
assert.deepEqual(
  JSON.parse(JSON.stringify(orderLeft.f.readDeviceAliasRecords()[aliasB])),
  JSON.parse(JSON.stringify(orderRight.f.readDeviceAliasRecords()[aliasB])),
  "equal-clock conflicting edits delivered in opposite orders must converge",
);
assert.equal(orderLeft.f.readDeviceAliasRecords()[aliasB].value, "Writer B");

const tombstoneLeft = aliasClient("alias-tombstone-left", [aliasA, aliasB]);
const tombstoneRight = aliasClient("alias-tombstone-right", [aliasA, aliasB]);
const equalValue = { schemaVersion: 1, updatedAt: tombstoneLeft.clock.now, value: "Value", writerId: "same-writer" };
const equalTombstone = { ...equalValue, value: null };
tombstoneLeft.f.mergeInventoryDeviceAliases(envelopeFor(equalValue), aliasA);
tombstoneLeft.f.mergeInventoryDeviceAliases(envelopeFor(equalTombstone), aliasA);
tombstoneRight.f.mergeInventoryDeviceAliases(envelopeFor(equalTombstone), aliasA);
tombstoneRight.f.mergeInventoryDeviceAliases(envelopeFor(equalValue), aliasA);
assert.equal(tombstoneLeft.f.readDeviceAliasRecords()[aliasB].value, null);
assert.equal(tombstoneRight.f.readDeviceAliasRecords()[aliasB].value, null, "a tombstone must win an otherwise exact tie regardless of delivery order");

const malformedClient = aliasClient("alias-malformed", [aliasA, aliasB]);
const malformedEnvelope = {
  schemaVersion: 1,
  selfAlias: { schemaVersion: 1, updatedAt: String(malformedClient.clock.now), value: "String clock", writerId: "peer" },
  records: {
    "invented-host": { schemaVersion: 1, updatedAt: malformedClient.clock.now, value: "Invented", writerId: "peer" },
    [aliasB]: { schemaVersion: 1, updatedAt: malformedClient.clock.now + 5 * 60 * 1000 + 1, value: "Future", writerId: "peer" },
  },
};
assert.equal(malformedClient.f.mergeInventoryDeviceAliases(malformedEnvelope, aliasA), false);
assert.deepEqual(Object.keys(malformedClient.f.readDeviceAliasRecords()), []);

const fullRecords = Object.fromEntries(Array.from({ length: 100 }, (_, index) => [
  `${aliasEnvironmentPrefix}full_${String(index).padStart(3, "0")}`,
  { schemaVersion: 1, updatedAt: 1, value: `Alias ${index}`, writerId: "fixture" },
]));
const fullFirstId = `${aliasEnvironmentPrefix}full_000`;
const fullOverflowId = `${aliasEnvironmentPrefix}full_overflow`;
const fullLegacyId = `${aliasEnvironmentPrefix}full_legacy`;
const fullClient = aliasClient("alias-full", [fullFirstId, fullOverflowId], [
  ["codex-remote-mobile-device-alias-records-v2", JSON.stringify(fullRecords)],
  ["codex-remote-mobile-device-aliases-v1", JSON.stringify({ [fullLegacyId]: "Must stay bounded" })],
]);
const overflowRecord = { schemaVersion: 1, updatedAt: fullClient.clock.now, value: "Overflow", writerId: "fixture" };
const fullBefore = fullClient.storage.get("codex-remote-mobile-device-alias-records-v2");
assert.equal(fullClient.f.mergeDeviceAliasRecords({ [fullOverflowId]: overflowRecord }, [fullOverflowId]), false);
assert.equal(fullClient.f.mergeDeviceAliasRecords({ [fullOverflowId]: overflowRecord }, [fullOverflowId]), false);
assert.equal(fullClient.storage.get("codex-remote-mobile-device-alias-records-v2"), fullBefore, "a dropped 101st key must not rewrite or repeatedly invalidate publication");
assert.equal(fullClient.f.saveDeviceAlias(fullFirstId, ""), true, "an existing record can still be reset at capacity");
assert.equal(Object.keys(fullClient.f.readDeviceAliasRecords()).length, 100);
assert.equal(fullClient.f.readDeviceAliasRecords()[fullFirstId].value, null);

const ceilingClient = aliasClient("alias-clock-ceiling", [aliasA]);
const ceilingRecord = { schemaVersion: 1, updatedAt: ceilingClient.clock.now + 5 * 60 * 1000, value: "Future alias", writerId: "zz-writer" };
ceilingClient.storage.set("codex-remote-mobile-device-alias-records-v2", JSON.stringify({ [aliasA]: ceilingRecord }));
ceilingClient.f.state.aliasDrafts.set(aliasA, "Fresh local edit");
const ceilingBefore = ceilingClient.storage.get("codex-remote-mobile-device-alias-records-v2");
assert.equal(ceilingClient.f.saveDeviceAlias(aliasA, "Fresh local edit"), false, "a local save must fail rather than lose at the accepted future-clock ceiling");
assert.equal(ceilingClient.storage.get("codex-remote-mobile-device-alias-records-v2"), ceilingBefore);
assert.equal(ceilingClient.f.state.aliasDrafts.get(aliasA), "Fresh local edit", "a clock-bound rejection must preserve the user's draft");
assert.match(ceilingClient.f.state.aliasFeedback.get(aliasA), /clock is too far ahead/u);

const legacyTombstone = { schemaVersion: 1, updatedAt: 10, value: null, writerId: "newer" };
const legacyClient = aliasClient("alias-legacy", [aliasA, aliasB], [
  ["codex-remote-mobile-device-alias-records-v2", JSON.stringify({ [aliasA]: legacyTombstone })],
  ["codex-remote-mobile-device-aliases-v1", JSON.stringify({ [aliasA]: "Stale legacy", [aliasB]: "Preserved legacy" })],
]);
const migrated = legacyClient.f.readDeviceAliasRecords();
assert.equal(migrated[aliasA].value, null, "late legacy migration must not revive an alias after a newer shared reset");
assert.deepEqual(JSON.parse(JSON.stringify(migrated[aliasB])), { schemaVersion: 1, updatedAt: 0, value: "Preserved legacy", writerId: "legacy" });
assert.equal(legacyClient.f.saveDeviceAlias(aliasB, "Preserved legacy"), true);
assert.ok(legacyClient.f.readDeviceAliasRecords()[aliasB].updatedAt > 0, "explicitly saving an unchanged legacy alias must promote it to a current shared edit");

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
  console.log(JSON.stringify({ aliasThreeClientConvergence: true, aliasOfflineResetReconnect: true, aliasEqualClockConvergence: true, aliasTombstoneTieWins: true, aliasFutureCeilingFailsClosed: true, aliasMalformedAndCapacityBounds: true, aliasNoEchoChurn: true, aliasLegacyMigration: true, aliasesSeparateFromIdentity: true, helperVersionRoundtrip: true, previewReadOnly: true, previewSingleflight: true, missingPinsFailClosed: true, actualCleanupHistory: true, boundedHistory: true, diagnosticsAllowlist: true }));
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => {
  f.state.disposed = true;
  if (f.state.autoArchiveTimer) clearTimeout(f.state.autoArchiveTimer);
  if (f.state.autoArchiveLeaseTimer) clearInterval(f.state.autoArchiveLeaseTimer);
});
