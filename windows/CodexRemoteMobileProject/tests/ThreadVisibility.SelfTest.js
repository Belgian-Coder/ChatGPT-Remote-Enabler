"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const originalSource = fs.readFileSync(rendererPath, "utf8");
const testSource = originalSource
  .replace("(() => {", "globalThis.__visibilityTest = (() => {")
  .replace("const AUTO_MAINTENANCE_RUN_LIMIT_MS = 90000;", "const AUTO_MAINTENANCE_RUN_LIMIT_MS = 40;")
  .replace(
    "  return install();\n})();",
    "  return { assignLocalRuntime, collectAuthoritativeThreadIds, directInventoryHasPriority, eligibleAutoArchiveThreads, eligibleAutoDeleteThreads, lexicalAbsolutePath, listAllLocalThreads, listAllRuntimeThreads, maintenanceThreadPathManaged, parseInventoryPayload, preferredThreadInventory, pruneVerifiedThreadIds, purgeLocalRuntimeAliases, rememberVerifiedThreadIds, removeGossipedLocalInventoryDuplicates, runAutoArchiveNow, runtimeThreadInventoryDue, sanitizedMaintenanceFailure, scopedThreadsAreFresh, serializePeerInventory, state, taskIsAuthoritative, unmanagedMaintenanceThreadCount };\n})();",
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
  __CODEX_REMOTE_MOBILE_CONFIG__: { localDisplayName: "Fixture-Local" },
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
  requestAnimationFrame: () => 1,
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
  hostDisplayName: "Fixture-Peer",
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
assert.equal(relayed.hostDisplayName, "Fixture-Peer");
const roundTripped = visibility.parseInventoryPayload({
  ...relayed,
  projects: [],
  schemaVersion: 1,
  tasks: [],
}, false);
assert.equal(roundTripped.threadScopeGeneratedAt, scoped.threadScopeGeneratedAt);
assert.equal(roundTripped.hostDisplayName, "Fixture-Peer");
assert.equal(visibility.scopedThreadsAreFresh(roundTripped), true);

const syntheticName = visibility.parseInventoryPayload({
  ...relayed,
  hostDisplayName: "Remote env_e_deadbeef",
  projects: [],
  schemaVersion: 1,
  tasks: [],
}, false);
assert.equal(syntheticName.hostDisplayName, null);

visibility.state.remoteProjectInventories.clear();
visibility.state.hostConnectivity.clear();
visibility.state.remoteCodexHomes.clear();
visibility.state.remoteRuntimeCache.clear();
visibility.state.threadInventories.set("local", { error: null, threads: [{ id: "local-user" }] });
visibility.state.localInventoryProjects = [{ cwd: "C:\\work\\local-project" }];

const selfEchoHostId = "remote-control:test-self";
const distinctSameNameHostId = "remote-control:test-distinct";
const directSameNameHostId = "remote-control:test-direct";
const relayToDirectConnectivityHostId = "remote-control:test-relay-to-direct-connectivity";
const relayToDirectRuntimeHostId = "remote-control:test-relay-to-direct-runtime";
const pathDriftSelfEchoHostId = "remote-control:test-path-drift-self";
const matchingLocalInventory = {
  error: null,
  fetchedAt: now,
  generatedAt: now,
  hostDisplayName: "Fixture-Local",
  projects: [{ cwd: "C:\\work\\local-project", rootPaths: ["C:\\work\\local-project"] }],
  threads: [{ id: "local-user" }],
  threadsAuthoritative: true,
};
visibility.state.remoteProjectInventories.set(selfEchoHostId, {
  ...matchingLocalInventory,
  sourcePeerHostId: "remote-control:test-relay",
});
visibility.state.hostConnectivity.set(selfEchoHostId, { available: false, checkedAt: now });
visibility.state.remoteCodexHomes.set(selfEchoHostId, "C:\\remote-home");
visibility.state.remoteRuntimeCache.set(selfEchoHostId, { requestClient: {} });
visibility.state.remoteRuntimeScannedAt = now;

visibility.state.remoteProjectInventories.set(distinctSameNameHostId, {
  ...matchingLocalInventory,
  hostDisplayName: "fixture-local",
  projects: [{ cwd: "D:\\work\\other-project", rootPaths: ["D:\\work\\other-project"] }],
  sourcePeerHostId: "remote-control:test-relay",
  threads: [{ id: "distinct-user" }],
});
visibility.state.hostConnectivity.set(distinctSameNameHostId, { available: false, checkedAt: now });

visibility.state.remoteProjectInventories.set(directSameNameHostId, {
  ...matchingLocalInventory,
  sourcePeerHostId: null,
});
visibility.state.hostConnectivity.set(directSameNameHostId, { available: true, checkedAt: now });
const directRuntime = { requestClient: { sendRequest() {} } };
visibility.state.remoteRuntimeCache.set(directSameNameHostId, directRuntime);

visibility.state.remoteProjectInventories.set(relayToDirectConnectivityHostId, {
  ...matchingLocalInventory,
  sourcePeerHostId: "remote-control:test-relay",
});
visibility.state.hostConnectivity.set(relayToDirectConnectivityHostId, { available: true, checkedAt: now });

visibility.state.remoteProjectInventories.set(relayToDirectRuntimeHostId, {
  ...matchingLocalInventory,
  sourcePeerHostId: "remote-control:test-relay",
});
visibility.state.hostConnectivity.set(relayToDirectRuntimeHostId, { available: false, checkedAt: now });
const relayToDirectRuntime = { requestClient: { sendRequest() {} } };
visibility.state.remoteRuntimeCache.set(relayToDirectRuntimeHostId, relayToDirectRuntime);

visibility.state.remoteProjectInventories.set(pathDriftSelfEchoHostId, {
  ...matchingLocalInventory,
  projects: [{ cwd: "E:\\work\\stale-local-alias", rootPaths: ["E:\\work\\stale-local-alias"] }],
  sourcePeerHostId: "remote-control:test-relay",
});
visibility.state.hostConnectivity.set(pathDriftSelfEchoHostId, { available: false, checkedAt: now });

visibility.removeGossipedLocalInventoryDuplicates();
assert.equal(visibility.state.remoteProjectInventories.has(selfEchoHostId), false);
assert.equal(visibility.state.hostConnectivity.has(selfEchoHostId), false);
assert.equal(visibility.state.remoteCodexHomes.has(selfEchoHostId), false);
assert.equal(visibility.state.remoteRuntimeCache.has(selfEchoHostId), false);
assert.equal(visibility.state.remoteRuntimeScannedAt, 0);
assert.equal(visibility.state.remoteProjectInventories.has(distinctSameNameHostId), true);
assert.equal(visibility.state.hostConnectivity.has(distinctSameNameHostId), true);
assert.equal(visibility.state.remoteProjectInventories.has(directSameNameHostId), true);
assert.equal(visibility.state.hostConnectivity.get(directSameNameHostId).available, true);
assert.equal(visibility.state.remoteRuntimeCache.get(directSameNameHostId), directRuntime);
assert.equal(visibility.state.remoteProjectInventories.has(relayToDirectConnectivityHostId), true);
assert.equal(visibility.state.hostConnectivity.get(relayToDirectConnectivityHostId).available, true);
assert.equal(visibility.state.remoteProjectInventories.has(relayToDirectRuntimeHostId), true);
assert.equal(visibility.state.hostConnectivity.get(relayToDirectRuntimeHostId).available, false);
assert.equal(visibility.state.remoteRuntimeCache.get(relayToDirectRuntimeHostId), relayToDirectRuntime);
assert.equal(visibility.state.remoteProjectInventories.has(pathDriftSelfEchoHostId), false);
assert.equal(visibility.state.hostConnectivity.has(pathDriftSelfEchoHostId), false);
assert.equal(visibility.state.localRuntimeHostIds.has(pathDriftSelfEchoHostId), true);

visibility.state.hostConnectivity.set(pathDriftSelfEchoHostId, { available: false, checkedAt: now });
visibility.state.remoteCodexHomes.set(pathDriftSelfEchoHostId, "C:\\orphan-home");
visibility.state.peerCacheStates.set(pathDriftSelfEchoHostId, { fetchedAt: now });
visibility.state.threadInventories.set(pathDriftSelfEchoHostId, { error: null, threads: [{ id: "local-user" }] });
visibility.state.threadManagers.set(pathDriftSelfEchoHostId, {});
visibility.state.verifiedThreadIds.set(pathDriftSelfEchoHostId, { ids: new Set(["local-user"]), verifiedAt: now });
visibility.state.remoteRuntimeCache.set(pathDriftSelfEchoHostId, { requestClient: { sendRequest() {} } });
visibility.purgeLocalRuntimeAliases();
for (const collection of [visibility.state.hostConnectivity, visibility.state.remoteCodexHomes, visibility.state.peerCacheStates, visibility.state.threadInventories, visibility.state.threadManagers, visibility.state.verifiedThreadIds, visibility.state.remoteRuntimeCache]) {
  assert.equal(collection.has(pathDriftSelfEchoHostId), false);
}

const authorityHostId = "remote-control:test-authority";
const healthyDirect = {
  error: null,
  fetchedAt: now,
  generatedAt: now,
  pending: false,
  sourcePeerCache: false,
  sourcePeerHostId: null,
};
visibility.state.hostConnectivity.set(authorityHostId, { available: true, checkedAt: now });
assert.equal(visibility.directInventoryHasPriority(authorityHostId, healthyDirect, now), true);
assert.equal(visibility.directInventoryHasPriority(authorityHostId, { ...healthyDirect, pending: true, sourcePeerHostId: "remote-control:test-relay" }, now), true);
assert.equal(visibility.directInventoryHasPriority(authorityHostId, { ...healthyDirect, error: "temporary failure" }, now), false);
assert.equal(visibility.directInventoryHasPriority(authorityHostId, { ...healthyDirect, fetchedAt: now - 30001 }, now), false);
assert.equal(visibility.directInventoryHasPriority(authorityHostId, { ...healthyDirect, sourcePeerHostId: "remote-control:test-relay" }, now), false);
assert.equal(visibility.directInventoryHasPriority(authorityHostId, { ...healthyDirect, sourcePeerCache: true }, now), false);
visibility.state.hostConnectivity.set(authorityHostId, { available: false, checkedAt: now });
visibility.state.remoteRuntimeCache.delete(authorityHostId);
assert.equal(visibility.directInventoryHasPriority(authorityHostId, healthyDirect, now), false);

const retryHostId = "remote-control:test-retry";
visibility.state.threadInventories.set(retryHostId, { error: "temporarily unavailable", retryAt: now + 60000, threads: [] });
assert.equal(visibility.runtimeThreadInventoryDue(retryHostId, now), false);
assert.equal(visibility.runtimeThreadInventoryDue(retryHostId, now + 60000), true);
visibility.state.threadInventories.set("local", { error: "temporary local failure", retryAt: now + 60000, threads: [] });
assert.equal(visibility.runtimeThreadInventoryDue("local", now), true);

assert.match(originalSource, /USER_VISIBLE_THREAD_SOURCE_KINDS = Object\.freeze\(\["cli", "vscode"\]\)/);
assert.equal((originalSource.match(/directInventoryHasPriority\(/gu) ?? []).length, 3);
assert.match(originalSource, /state\.inventoryHydrationRounds = 0;/u);
assert.doesNotMatch(originalSource, /inventoryHydrationPending = true;\s*state\.inventoryHydrationError = null;/u);
assert.match(originalSource, /MAX_THREAD_LIST_PAGES = 200;/u);
assert.match(originalSource, /retryAt: Date\.now\(\) \+ NATIVE_INVENTORY_ERROR_RETRY_MS/u);
assert.match(originalSource, /finally \{\s*state\.inventoryHydrationPending = false;/u);
assert.doesNotMatch(originalSource, /!authoritativeIds\.has\(task\.hostId\) && !task\.selected/);
assert.match(originalSource, /threadScopeGeneratedAt/);

(async () => {
  let pageCalls = 0;
  const changingCursorClient = {
    async sendRequest() {
      pageCalls += 1;
      return { data: [{ id: `thread-${pageCalls}` }], nextCursor: `cursor-${pageCalls}` };
    },
  };
  const bounded = await visibility.listAllRuntimeThreads(changingCursorClient, false, Number.POSITIVE_INFINITY, false);
  assert.equal(pageCalls, 200);
  assert.equal(bounded.pages, 200);
  assert.equal(bounded.truncated, true);
  assert.equal(bounded.threads.length, 200);

  pageCalls = 0;
  await assert.rejects(
    visibility.listAllRuntimeThreads(changingCursorClient, false, Number.POSITIVE_INFINITY, true),
    /bounded page limit/,
  );
  assert.equal(pageCalls, 200);

  const requestShapes = [];
  const shapeClient = {
    async sendRequest(method, params) {
      assert.equal(method, "thread/list");
      requestShapes.push(params);
      return { data: [], nextCursor: null };
    },
  };
  await visibility.listAllRuntimeThreads(shapeClient, false, Date.now() + 1000, false);
  await visibility.listAllRuntimeThreads(shapeClient, true, Date.now() + 1000, true);
  assert.equal(Object.hasOwn(requestShapes[0], "useStateDbOnly"), false);
  assert.equal(requestShapes[1].useStateDbOnly, true);
  assert.equal(requestShapes[1].sourceKinds.includes("appServer"), true);

  visibility.state.localCodexHome = "D:\\Fixture\\.codex";
  assert.equal(visibility.maintenanceThreadPathManaged({ path: "d:/FIXTURE/.codex/sessions/2026/thread.jsonl" }, false), true);
  assert.equal(visibility.maintenanceThreadPathManaged({ path: "D:\\Fixture\\.codex\\archived_sessions\\thread.jsonl" }, true), true);
  assert.equal(visibility.maintenanceThreadPathManaged({ path: "D:\\Fixture\\.codex\\sessions-old\\thread.jsonl" }, false), false);
  assert.equal(visibility.maintenanceThreadPathManaged({ path: "D:\\Fixture\\.codex\\sessions\\..\\legacy\\thread.jsonl" }, false), false);
  assert.equal(visibility.maintenanceThreadPathManaged({ path: null }, false), true);
  visibility.state.localCodexHome = "/opt/fixture/.codex";
  assert.equal(visibility.maintenanceThreadPathManaged({ path: "/opt/fixture/.codex/sessions/2026/thread.jsonl" }, false), true);
  assert.equal(visibility.maintenanceThreadPathManaged({ path: "/opt/fixture/.codex/archived_sessions/thread.jsonl" }, true), true);
  assert.equal(visibility.maintenanceThreadPathManaged({ path: "/opt/Fixture/.codex/sessions/thread.jsonl" }, false), false);
  assert.equal(visibility.maintenanceThreadPathManaged({ path: "/opt/fixture/.codex/sessions-backup/thread.jsonl" }, false), false);
  visibility.state.localCodexHome = null;
  assert.equal(visibility.maintenanceThreadPathManaged({ path: "/legacy/thread.jsonl" }, false), true);

  const sanitized = visibility.sanitizedMaintenanceFailure("archive", new Error("rollout path D:\\Private\\thread.jsonl is outside sessions for 00000000-0000-0000-0000-000000000000"));
  assert.equal(sanitized, "Archive skipped a chat outside the managed Codex sessions directory");
  assert.doesNotMatch(sanitized, /Private|00000000/);

  let concurrentLists = 0;
  let maxConcurrentLists = 0;
  let serializedListCalls = 0;
  const serializedClient = {
    sendRequest(method) {
      assert.equal(method, "thread/list");
      serializedListCalls += 1;
      concurrentLists += 1;
      maxConcurrentLists = Math.max(maxConcurrentLists, concurrentLists);
      return new Promise((resolve) => setTimeout(() => {
        concurrentLists -= 1;
        resolve({ data: [], nextCursor: null });
      }, 5));
    },
  };
  visibility.assignLocalRuntime(null, serializedClient);
  const serializedGeneration = visibility.state.localRuntimeGeneration;
  await Promise.all([
    visibility.listAllLocalThreads(serializedClient, false, Date.now() + 1000, true, "serialized active", serializedGeneration),
    visibility.listAllLocalThreads(serializedClient, true, Date.now() + 1000, true, "serialized archived", serializedGeneration),
  ]);
  assert.equal(serializedListCalls, 2);
  assert.equal(maxConcurrentLists, 1);

  let releaseTimedOutRequest;
  let heldGateCalls = 0;
  concurrentLists = 0;
  maxConcurrentLists = 0;
  const heldGateClient = {
    sendRequest() {
      heldGateCalls += 1;
      concurrentLists += 1;
      maxConcurrentLists = Math.max(maxConcurrentLists, concurrentLists);
      if (heldGateCalls === 1) {
        return new Promise((resolve) => {
          releaseTimedOutRequest = () => {
            concurrentLists -= 1;
            resolve({ data: [], nextCursor: null });
          };
        });
      }
      concurrentLists -= 1;
      return Promise.resolve({ data: [], nextCursor: null });
    },
  };
  visibility.assignLocalRuntime(null, heldGateClient);
  const heldGeneration = visibility.state.localRuntimeGeneration;
  await assert.rejects(
    visibility.listAllLocalThreads(heldGateClient, false, Date.now() + 15, true, "timed out active", heldGeneration),
    /timed out active/,
  );
  const queuedAfterTimeout = visibility.listAllLocalThreads(heldGateClient, true, Date.now() + 500, true, "queued archived", heldGeneration);
  await new Promise((resolve) => setTimeout(resolve, 15));
  assert.equal(heldGateCalls, 1, "a timed-out underlying request must continue holding the gate");
  let replacementGateCalls = 0;
  const replacementGateClient = {
    async sendRequest() {
      replacementGateCalls += 1;
      return { data: [], nextCursor: null };
    },
  };
  visibility.assignLocalRuntime(null, replacementGateClient);
  await visibility.listAllLocalThreads(replacementGateClient, false, Date.now() + 200, true, "replacement active", visibility.state.localRuntimeGeneration);
  assert.equal(replacementGateCalls, 1, "a replacement runtime must not queue behind a dead client gate");
  assert.equal(heldGateCalls, 1, "the same-client retry must remain blocked until the old request settles");
  releaseTimedOutRequest();
  await assert.rejects(queuedAfterTimeout, /runtime changed/);
  assert.equal(heldGateCalls, 1);

  const old = Date.now() - 8 * 24 * 60 * 60 * 1000;
  const protectedThreads = [
    { id: "eligible", path: "d:/FIXTURE/.codex/sessions/2026/eligible.jsonl", status: "notLoaded", updatedAt: old },
    { id: "eligible-two", path: "D:\\Fixture\\.codex\\sessions\\2026\\eligible-two.jsonl", status: "notLoaded", updatedAt: old },
    { id: "unmanaged", path: "D:\\Fixture\\.codex\\sessions-old\\unmanaged.jsonl", status: "notLoaded", updatedAt: old },
    { id: "pinned", status: "notLoaded", updatedAt: old },
    { id: "selected", selected: true, status: "notLoaded", updatedAt: old },
    { id: "loading", status: "active", updatedAt: old },
    { id: "parent", status: "notLoaded", updatedAt: old },
    { id: "child", parentThreadId: "parent", status: "active", updatedAt: old },
  ];
  let maintenanceListCalls = 0;
  const mutations = [];
  const maintenanceClient = {
    async sendRequest(method, params) {
      if (method === "thread/list") {
        maintenanceListCalls += 1;
        assert.equal(params.useStateDbOnly, true);
        return { data: params.archived ? [] : protectedThreads, nextCursor: null };
      }
      mutations.push({ method, params });
      return {};
    },
  };
  storage.set("codex-remote-mobile-auto-archive-enabled-v1", "true");
  visibility.state.localCodexHome = "D:\\Fixture\\.codex";
  visibility.state.localFetchFromHost = async () => ({ value: ["pinned"] });
  visibility.assignLocalRuntime(visibility.state.localFetchFromHost, maintenanceClient);
  visibility.state.autoArchivePending = false;
  visibility.state.autoArchiveError = null;
  const maintenanceResult = await visibility.runAutoArchiveNow();
  if (visibility.state.autoArchiveTimer !== null) clearTimeout(visibility.state.autoArchiveTimer);
  visibility.state.autoArchiveTimer = null;
  assert.equal(maintenanceListCalls, 4, "maintenance must take initial and immediate pre-mutation active/archived snapshots");
  assert.equal(mutations.length, 1);
  assert.equal(mutations[0].method, "thread/archive");
  assert.equal(mutations[0].params.threadId, "eligible");
  assert.equal(maintenanceResult.archived, 1);
  assert.equal(maintenanceResult.continuationScheduled, true);
  assert.equal(maintenanceResult.unmanagedActiveSkipped, 1);
  assert.equal(maintenanceResult.unmanagedArchivedSkipped, 0);
  assert.equal(visibility.state.autoArchivePending, false);

  let archiveRaceActiveLists = 0;
  const archiveRaceMutations = [];
  const archiveRaceClient = {
    async sendRequest(method, params) {
      if (method !== "thread/list") {
        archiveRaceMutations.push(method);
        return {};
      }
      if (params.archived) return { data: [], nextCursor: null };
      archiveRaceActiveLists += 1;
      return {
        data: [{
          id: "archive-race",
          path: "D:\\Fixture\\.codex\\sessions\\archive-race.jsonl",
          status: archiveRaceActiveLists === 1 ? "notLoaded" : "active",
          updatedAt: old,
        }],
        nextCursor: null,
      };
    },
  };
  visibility.assignLocalRuntime(visibility.state.localFetchFromHost, archiveRaceClient);
  visibility.state.autoArchivePending = false;
  const archiveRaceResult = await visibility.runAutoArchiveNow();
  if (visibility.state.autoArchiveTimer !== null) clearTimeout(visibility.state.autoArchiveTimer);
  visibility.state.autoArchiveTimer = null;
  assert.equal(archiveRaceActiveLists, 2);
  assert.equal(archiveRaceResult.archived, 0);
  assert.deepEqual(archiveRaceMutations, []);

  let deleteRaceActiveLists = 0;
  let deleteRaceArchivedLists = 0;
  const deleteRaceMutations = [];
  storage.set("codex-remote-mobile-auto-archived-records-v1", JSON.stringify({ "delete-race": old }));
  const deleteRaceClient = {
    async sendRequest(method, params) {
      if (method !== "thread/list") {
        deleteRaceMutations.push(method);
        return {};
      }
      if (params.archived) {
        deleteRaceArchivedLists += 1;
        return {
          data: deleteRaceArchivedLists === 1 ? [{ id: "delete-race", path: "D:\\Fixture\\.codex\\archived_sessions\\delete-race.jsonl", status: "notLoaded" }] : [],
          nextCursor: null,
        };
      }
      deleteRaceActiveLists += 1;
      return {
        data: deleteRaceActiveLists === 1 ? [] : [{ id: "delete-race", path: "D:\\Fixture\\.codex\\sessions\\delete-race.jsonl", status: "active", updatedAt: Date.now() }],
        nextCursor: null,
      };
    },
  };
  visibility.assignLocalRuntime(visibility.state.localFetchFromHost, deleteRaceClient);
  visibility.state.autoArchivePending = false;
  const deleteRaceResult = await visibility.runAutoArchiveNow();
  if (visibility.state.autoArchiveTimer !== null) clearTimeout(visibility.state.autoArchiveTimer);
  visibility.state.autoArchiveTimer = null;
  assert.equal(deleteRaceResult.deleted, 0);
  assert.deepEqual(deleteRaceMutations, []);

  const failingMaintenanceClient = {
    async sendRequest(method, params) {
      if (method === "thread/list") {
        return {
          data: params.archived ? [] : [{ id: "failure-id", path: "D:\\Fixture\\.codex\\sessions\\failure.jsonl", status: "notLoaded", updatedAt: old }],
          nextCursor: null,
        };
      }
      throw new Error("rollout path D:\\Private\\failure.jsonl is outside sessions for failure-id");
    },
  };
  visibility.assignLocalRuntime(visibility.state.localFetchFromHost, failingMaintenanceClient);
  visibility.state.autoArchivePending = false;
  const failureResult = await visibility.runAutoArchiveNow();
  if (visibility.state.autoArchiveTimer !== null) clearTimeout(visibility.state.autoArchiveTimer);
  visibility.state.autoArchiveTimer = null;
  assert.equal(failureResult.operationError, "Archive skipped a chat outside the managed Codex sessions directory");
  assert.match(failureResult.error ?? visibility.state.autoArchiveError, /Archive skipped a chat outside/);
  assert.doesNotMatch(JSON.stringify(failureResult), /Private|failure-id/);
  assert.equal(visibility.state.autoArchivePending, false);

  const archivedPathThreads = [
    { id: "archived-managed", path: "D:\\Fixture\\.codex\\archived_sessions\\managed.jsonl", status: "notLoaded" },
    { id: "archived-unmanaged", path: "D:\\Fixture\\.codex\\archived_sessions-old\\unmanaged.jsonl", status: "notLoaded" },
    { id: "archived-legacy-api", status: "notLoaded" },
  ];
  const archiveRecords = Object.fromEntries(archivedPathThreads.map((thread) => [thread.id, old]));
  assert.deepEqual(
    visibility.eligibleAutoDeleteThreads(archivedPathThreads, [], archiveRecords).map((thread) => thread.id),
    ["archived-managed", "archived-legacy-api"],
  );
  assert.equal(visibility.unmanagedMaintenanceThreadCount(archivedPathThreads, true), 1);
  visibility.state.localCodexHome = null;

  let originalClientMutations = 0;
  let replacementClientMutations = 0;
  const replacementClient = {
    async sendRequest(method) {
      if (method !== "thread/list") replacementClientMutations += 1;
      return { data: [], nextCursor: null };
    },
  };
  const swappingClient = {
    async sendRequest(method, params) {
      if (method !== "thread/list") {
        originalClientMutations += 1;
        return {};
      }
      if (!params.archived) visibility.assignLocalRuntime(visibility.state.localFetchFromHost, replacementClient);
      return { data: params.archived ? [] : [{ id: "swap-eligible", status: "notLoaded", updatedAt: old }], nextCursor: null };
    },
  };
  visibility.assignLocalRuntime(visibility.state.localFetchFromHost, swappingClient);
  visibility.state.autoArchivePending = false;
  const swapResult = await visibility.runAutoArchiveNow();
  if (visibility.state.autoArchiveTimer !== null) clearTimeout(visibility.state.autoArchiveTimer);
  visibility.state.autoArchiveTimer = null;
  assert.match(swapResult.error, /runtime changed/);
  assert.equal(originalClientMutations, 0);
  assert.equal(replacementClientMutations, 0);
  assert.equal(visibility.state.autoArchivePending, false);

  const neverSettlesClient = { sendRequest: () => new Promise(() => {}) };
  visibility.assignLocalRuntime(visibility.state.localFetchFromHost, neverSettlesClient);
  visibility.state.autoArchivePending = false;
  const timeoutResult = await visibility.runAutoArchiveNow();
  if (visibility.state.autoArchiveTimer !== null) clearTimeout(visibility.state.autoArchiveTimer);
  visibility.state.autoArchiveTimer = null;
  assert.match(timeoutResult.error, /maintenance active snapshot/);
  assert.equal(visibility.state.autoArchivePending, false);
  console.log("Thread visibility self-test passed.");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
