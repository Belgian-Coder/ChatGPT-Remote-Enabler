"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const events = require("node:events");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

const root = path.resolve(__dirname, "..");
const windowsModulePath = path.join(root, "windows", "CodexRemoteMobileProject", "update-session.js");
const macModulePath = path.join(root, "macos", "update-session.js");
const session = require(windowsModulePath);
const handoffHelper = require(path.join(root, "windows", "CodexRemoteMobileProject", "coordinator-handoff.js"));

assert.equal(fs.readFileSync(windowsModulePath, "utf8"), fs.readFileSync(macModulePath, "utf8"), "platform update-session controllers must stay mirrored");
assert.deepEqual(session.canonicalStatus({ state: "available", version: "v1.2.3", message: "ok", canQueue: true, extra: 1 }), {
  state: "available", version: "v1.2.3", message: "ok", canCancel: false, canQueue: true,
});
assert.deepEqual(session.parseLastJson('{\n  "available": true,\n  "latestVersion": "v2.0.0"\n}\n'), { available: true, latestVersion: "v2.0.0" });

const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "chatgpt-remote-update-session-unit-"));
const stateRoot = path.join(tempRoot, "state");
const sessionDirectory = path.join(stateRoot, "sessions", "fixture");
const bundleRoot = path.join(stateRoot, "bundles", "a".repeat(64));
const installRoot = path.join(tempRoot, "install");
fs.mkdirSync(sessionDirectory, { recursive: true });
fs.mkdirSync(bundleRoot, { recursive: true });
fs.mkdirSync(installRoot, { recursive: true });
fs.writeFileSync(path.join(installRoot, "VERSION"), "v1.0.0\n");

function config(overrides = {}) {
  return {
    schemaVersion: 1,
    platform: "win32",
    installRoot,
    stateRoot,
    sessionDirectory,
    updaterPath: path.join(bundleRoot, "Update-ChatGPTRemote.ps1"),
    platformHelperPath: path.join(bundleRoot, "UpdateSessionPlatform.ps1"),
    rendererPort: 24547,
    autoCheckEnabled: true,
    skipInitialCheck: false,
    logPath: path.join(sessionDirectory, "update-session.log"),
    app: { pid: 4321, startTimeFileTimeUtc: "134000000000000000", executablePath: path.join(tempRoot, "ChatGPT.exe") },
    relaunch: { entryPointRelative: "CodexRemoteMobileProject\\MobileProjectStartup.ps1", useProxy: true, replaceRunningApp: true },
    activityPollMs: 0,
    idleRecheckMs: 0,
    ...overrides,
  };
}

assert.equal(session.ensureConfig(config()).app.startTimeFileTimeUtc, "134000000000000000");
assert.throws(() => session.ensureConfig(config({ sessionDirectory: tempRoot })), /outside the per-user session root/u);
assert.throws(() => session.safeRemovePrepared(config(), tempRoot), /outside the update-session prepared root/u);

function harness(options = {}) {
  const statuses = [];
  const calls = { apply: 0, check: 0, close: 0, closingExpected: [], handoff: 0, hotReload: 0, hotReloadVersions: [], isAlive: 0, notify: 0, prepare: 0, probe: 0, recover: 0, relaunch: 0, removed: [] };
  const release = { version: "v1.5.32", archiveSha256: "b".repeat(64) };
  const activities = [...(options.activities ?? [{ known: true, busy: false }, { known: true, busy: false }])];
  const retained = path.join(sessionDirectory, "prepared", release.version, "verified");
  const transport = {
    async publish(status) { statuses.push({ ...status }); },
    async queryActivity() { return activities.length ? activities.shift() : { known: true, busy: false }; },
    setClosingExpected(value) { calls.closingExpected.push(value); },
  };
  const updater = {
    async check() { calls.check += 1; return { available: true, latestVersion: release.version, localVersion: "v1.0.0", archiveSha256: release.archiveSha256 }; },
    async prepare(actual, directory) {
      calls.prepare += 1;
      calls.preparedRelease = { ...actual };
      calls.preparedDirectory = directory;
      if (options.prepare) return options.prepare(actual, directory, retained);
      return { prepared: true, preparedPath: retained, version: actual.version, archiveSha256: actual.archiveSha256 };
    },
    async applyPrepared(actual, directory) {
      calls.apply += 1;
      calls.appliedRelease = { ...actual };
      calls.appliedDirectory = directory;
      if (options.applyError) throw options.applyError;
      return { updated: true, version: actual.version, archiveSha256: actual.archiveSha256 };
    },
    async recover() {
      calls.recover += 1;
      if (options.recoverError) throw options.recoverError;
      return { recovered: false, integrityValid: true };
    },
  };
  const platform = {
    async probe() { calls.probe += 1; return options.probe ? options.probe() : options.running !== false; },
    isAlive() { calls.isAlive += 1; return options.alive !== false; },
    async closeGracefully() { calls.close += 1; return options.closeResult !== false; },
    async hotReload(actual) {
      calls.hotReload += 1;
      calls.hotReloadVersions.push(actual.version);
      if (options.hotReloadError && calls.hotReload === 1) throw options.hotReloadError;
      return { loaded: true, helperVersion: actual.version, rendererVersion: 82, ready: true };
    },
    async handoffCoordinator() { calls.handoff += 1; if (options.handoffError) throw options.handoffError; return { activated: true }; },
    async relaunch() { calls.relaunch += 1; if (options.relaunchError) throw options.relaunchError; return { ready: true }; },
    async notifyFailure() { calls.notify += 1; },
  };
  const controller = new session.UpdateSessionController(config(), {
    transport,
    updater,
    platform,
    sleep: async () => {},
    isWritable: () => options.writable !== false,
    canHotReload: () => ({ compatible: options.hotCompatible === true, reason: "fixture" }),
    removePrepared: (directory) => calls.removed.push(directory),
  });
  return { activities, calls, controller, release, statuses, retained };
}

async function waitOperation(controller) {
  while (controller.queueRequestPromise) await controller.queueRequestPromise;
  if (controller.operationPromise) await controller.operationPromise;
}

function testPersistentHistory() {
  const first = path.join(stateRoot, "sessions", "history-first");
  const second = path.join(stateRoot, "sessions", "history-second");
  fs.mkdirSync(first); fs.mkdirSync(second);
  const now = Date.now();
  const originalRename = fs.renameSync;
  let transientRenameFailures = 0;
  fs.renameSync = (source, destination) => {
    if (process.platform === "win32" && transientRenameFailures < 2 && destination.endsWith("update-history-v1.json")) {
      transientRenameFailures += 1;
      const error = new Error("temporary endpoint-scanner lock");
      error.code = "EPERM";
      throw error;
    }
    return originalRename(source, destination);
  };
  try {
    session.appendUpdateHistory(config({ sessionDirectory: first }), { at: now - 10, state: "checked", version: "v1.0.0", privateMessage: "must not persist" });
  } finally {
    fs.renameSync = originalRename;
  }
  if (process.platform === "win32") assert.equal(transientRenameFailures, 2);
  session.appendUpdateHistory(config({ sessionDirectory: first }), { at: now - 9, state: "updating", version: "v2.0.0" });
  session.appendUpdateHistory(config({ sessionDirectory: second }), { at: now - 8, state: "restart-confirmed", version: "v2.0.0" });
  const entries = session.readUpdateHistory(config({ sessionDirectory: second }));
  assert.ok(entries.some(entry => entry.state === "updating"));
  assert.ok(entries.some(entry => entry.state === "restart-confirmed"));
  assert.doesNotMatch(JSON.stringify(entries), /privateMessage|must not persist/);
  assert.throws(() => session.appendUpdateHistory(config({ sessionDirectory: tempRoot }), { at: now, state: "current" }), /owned session/);
  fs.writeFileSync(path.join(first, "update-history-v1.json"), "broken JSON");
  assert.ok(session.readUpdateHistory(config()).some(entry => entry.state === "restart-confirmed"), "a corrupt session must not hide good history");
  for (let index = 0; index < 105; index++) session.appendUpdateHistory(config({ sessionDirectory: second }), { at: now + index, state: "available", version: "v2.0.0" });
  assert.equal(JSON.parse(fs.readFileSync(path.join(second, "update-history-v1.json"), "utf8")).length, 100);
  assert.equal(session.readUpdateHistory(config()).length, 100);
  fs.rmSync(first, {recursive:true}); fs.rmSync(second, {recursive:true});
}

async function testReadOnlyHistoryRefresh() {
  const h = harness();
  const historyPath = path.join(sessionDirectory, "update-history-v1.json");
  const existed = fs.existsSync(historyPath);
  await h.controller.request("history", "history-initial");
  assert.equal(fs.existsSync(historyPath), existed, "opening initial history must not create an event file");
  const late = { at: Date.now(), state: "restart-confirmed", version: "v8.7.6" };
  session.appendUpdateHistory(config(), late);
  const before = fs.readFileSync(historyPath, "utf8");
  const status = await h.controller.request("history", "history-late");
  assert.ok(status.details.history.some(entry => entry.version === late.version));
  assert.equal(fs.readFileSync(historyPath, "utf8"), before, "refresh must not write history");
  for (const key of ["check", "prepare", "apply", "close", "relaunch"]) assert.equal(h.calls[key], 0);
}

async function testPinnedIdleFlow() {
  const h = harness({ activities: [
    { known: false, busy: false, reason: "Inventory is still loading." },
    { known: true, busy: true, reason: "An internal task is active." },
    { known: true, busy: false },
    { known: true, busy: false },
  ] });
  await h.controller.check(true);
  await h.controller.request("queue", "queue-1");
  await waitOperation(h.controller);
  assert.deepEqual(h.calls.preparedRelease, h.release, "Prepare must receive only the release pinned by Check");
  assert.deepEqual(h.calls.appliedRelease, h.release, "Apply must reuse the same pinned release");
  assert.equal(h.calls.appliedDirectory, h.retained, "Apply must retain the exact preparedPath returned by Prepare");
  assert.equal(h.calls.close, 1);
  assert.equal(h.calls.apply, 1);
  assert.equal(h.calls.recover, 1);
  assert.equal(h.calls.relaunch, 1);
  assert.ok(h.controller.history.some(entry => entry.state === "restart-confirmed" && entry.version === h.release.version));
  assert.equal(h.controller.status.details.installedVersion, h.release.version);
  assert.ok(h.statuses.some((value) => value.state === "queued" && /Inventory/u.test(value.message)));
  assert.ok(h.statuses.some((value) => value.state === "closing" && value.canCancel === false));
}

async function testPinnedHotReloadFlow() {
  const h = harness({ hotCompatible: true });
  await h.controller.check(true);
  await h.controller.request("queue", "queue-hot");
  await waitOperation(h.controller);
  assert.equal(h.calls.apply, 1);
  assert.equal(h.calls.recover, 1);
  assert.equal(h.calls.hotReload, 1);
  assert.equal(h.calls.handoff, 1, "a compatible update must schedule the installed coordinator replacement");
  assert.equal(h.calls.close, 0, "a compatible update must not close ChatGPT");
  assert.equal(h.calls.relaunch, 0, "a compatible update must not relaunch ChatGPT");
  assert.equal(h.controller.stopping, true, "the predecessor controller must retire after the installed coordinator is active");
  assert.equal(h.controller.status.state, "current");
  assert.equal(h.controller.status.details.installedVersion, h.release.version);
  assert.match(h.controller.status.message, /without restarting ChatGPT/u);
  assert.ok(h.controller.history.some(entry => entry.state === "hot-reload-confirmed" && entry.version === h.release.version));
}

async function testCoordinatorActivationFailureKeepsAppOpen() {
  const h = harness({ hotCompatible: true, handoffError: new Error("simulated coordinator activation failure") });
  await h.controller.check(true);
  await h.controller.request("queue", "queue-activation-failure");
  await waitOperation(h.controller);
  assert.equal(h.calls.handoff, 3);
  assert.equal(h.calls.close, 0, "coordinator activation failure must not close ChatGPT");
  assert.equal(h.calls.relaunch, 0, "coordinator activation failure must not relaunch ChatGPT");
  assert.equal(h.controller.stopping, false, "the predecessor must remain available when activation fails");
  assert.equal(h.controller.status.state, "current");
}

async function testIncompleteHandoffRecoveryStopsRetries() {
  const failure = new Error("simulated predecessor recovery failure");
  failure.handoffRecoveryIncomplete = true;
  const h = harness({ hotCompatible: true, handoffError: failure });
  await h.controller.check(true);
  await h.controller.request("queue", "queue-incomplete-handoff-recovery");
  await waitOperation(h.controller);
  assert.equal(h.calls.handoff, 1, "an incomplete predecessor recovery must stop automatic handoff retries");
  assert.equal(h.controller.stopping, true, "a predecessor without its lock or transport must retire instead of claiming it remains active");
}

function testCoordinatorAwareRetention() {
  const retentionRoot = path.join(tempRoot, "retention-state");
  const sessionsRoot = path.join(retentionRoot, "sessions");
  const bundlesRoot = path.join(retentionRoot, "bundles");
  fs.mkdirSync(sessionsRoot, { recursive: true });
  fs.mkdirSync(bundlesRoot, { recursive: true });
  const ids = Array.from({ length: 5 }, (_, index) => String(index + 1).repeat(32));
  const hashes = Array.from({ length: 5 }, (_, index) => (index + 10).toString(16).repeat(64).slice(0, 64));
  ids.forEach((id, index) => {
    const directory = path.join(sessionsRoot, id);
    const bundle = path.join(bundlesRoot, hashes[index]);
    fs.mkdirSync(directory, { recursive: true });
    fs.mkdirSync(bundle, { recursive: true });
    fs.writeFileSync(path.join(bundle, "Update-ChatGPTRemote.ps1"), "fixture");
    fs.writeFileSync(path.join(directory, "session.json"), JSON.stringify({ app: { pid: process.pid }, updaterPath: path.join(bundle, "Update-ChatGPTRemote.ps1") }));
    fs.writeFileSync(path.join(directory, "coordinator-state.json"), JSON.stringify({
      phase: index === 4 ? "active" : "stopped",
      coordinatorPid: process.pid,
      heartbeatAtUnixMs: Date.now(),
    }));
    const age = new Date(Date.now() - ((5 - index) * 1000));
    fs.utimesSync(directory, age, age);
    fs.utimesSync(bundle, age, age);
  });
  const orphanBundle = path.join(bundlesRoot, "f".repeat(64));
  fs.mkdirSync(orphanBundle, { recursive: true });
  fs.writeFileSync(path.join(orphanBundle, "Update-ChatGPTRemote.ps1"), "orphan fixture");
  const newest = new Date(Date.now() + 1000);
  fs.utimesSync(orphanBundle, newest, newest);
  const currentDirectory = path.join(sessionsRoot, ids[4]);
  session.pruneUpdateSessionState({ stateRoot: retentionRoot, sessionDirectory: currentDirectory }, 2, 2);
  assert.deepEqual(fs.readdirSync(sessionsRoot).sort(), ids.slice(3).sort(), "retention must keep the active coordinator and one prior session");
  assert.deepEqual(fs.readdirSync(bundlesRoot).sort(), hashes.slice(3).sort(), "retention must keep only the current and previous bundles");
}

async function testHotReloadFailureKeepsAppOpen() {
  const h = harness({ hotCompatible: true, hotReloadError: new Error("simulated reload failure") });
  await h.controller.check(true);
  await h.controller.queue();
  await waitOperation(h.controller);
  assert.equal(h.calls.apply, 0, "file replacement must not start when prepared live reload fails");
  assert.equal(h.calls.recover, 0);
  assert.equal(h.calls.hotReload, 2, "a partially activated candidate must be replaced by the still-installed prior renderer");
  assert.deepEqual(h.calls.hotReloadVersions, [h.release.version, "v1.0.0"], "the rollback reload must use the exact prior installed version");
  assert.equal(h.calls.close, 0);
  assert.equal(h.calls.relaunch, 0);
  assert.equal(h.calls.notify, 0);
  assert.equal(h.controller.stopping, false);
  assert.equal(h.controller.status.state, "error");
}

async function testHotApplyFailureRestoresPriorRenderer() {
  const h = harness({ hotCompatible: true, applyError: new Error("simulated apply failure") });
  await h.controller.check(true);
  await h.controller.queue();
  await waitOperation(h.controller);
  assert.equal(h.calls.apply, 1);
  assert.equal(h.calls.recover, 1);
  assert.equal(h.calls.hotReload, 2, "the prepared renderer and recovered prior renderer must each load once");
  assert.equal(h.calls.close, 0);
  assert.equal(h.calls.relaunch, 0);
  assert.equal(h.controller.stopping, false);
  assert.equal(h.controller.status.state, "error");
}

function testHotReloadCompatibility() {
  const prepared = path.join(sessionDirectory, "prepared", "compatibility");
  const coldRelative = "CodexRemoteSimple/runtime/orchestrator.js";
  const publisherRelative = "CodexRemoteMobileProject/publisher-heartbeat.js";
  for (const relative of [coldRelative, publisherRelative]) {
    const installed = path.join(installRoot, ...relative.split("/"));
    const candidate = path.join(prepared, ...relative.split("/"));
    fs.mkdirSync(path.dirname(installed), { recursive: true });
    fs.mkdirSync(path.dirname(candidate), { recursive: true });
    fs.writeFileSync(installed, relative);
    fs.writeFileSync(candidate, relative);
  }
  const manifest = [coldRelative, publisherRelative].map((relative) =>
    `${crypto.createHash("sha256").update(relative).digest("hex")} *${relative}`
  ).join("\n") + "\n";
  fs.writeFileSync(path.join(prepared, "RELEASE-MANIFEST.sha256"), manifest);
  fs.writeFileSync(path.join(installRoot, "RELEASE-MANIFEST.sha256"), manifest);
  assert.equal(session.hotReloadCompatibility(config(), prepared).compatible, true);

  const scriptRelative = "CodexRemoteSimple/CodexRemoteSimple.ps1";
  const installedScript = path.join(installRoot, ...scriptRelative.split("/"));
  const candidateScript = path.join(prepared, ...scriptRelative.split("/"));
  fs.mkdirSync(path.dirname(installedScript), { recursive: true });
  fs.mkdirSync(path.dirname(candidateScript), { recursive: true });
  fs.writeFileSync(installedScript, "Write-Output one\r\nWrite-Output two\r\n");
  fs.writeFileSync(candidateScript, "Write-Output one\nWrite-Output two\n");
  const manifestFor = (root, relatives) => relatives.map((relative) => {
    const file = path.join(root, ...relative.split("/"));
    return `${crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex")} *${relative}`;
  }).join("\n") + "\n";
  const completeRelatives = [coldRelative, publisherRelative, scriptRelative];
  fs.writeFileSync(path.join(prepared, "RELEASE-MANIFEST.sha256"), manifestFor(prepared, completeRelatives));
  fs.writeFileSync(path.join(installRoot, "RELEASE-MANIFEST.sha256"), manifestFor(installRoot, completeRelatives));
  assert.equal(session.hotReloadCompatibility(config(), prepared).compatible, true,
    "PowerShell line-ending conversion must not force a ChatGPT restart");
  fs.writeFileSync(candidateScript, "Write-Output one\nWrite-Output changed\n");
  fs.writeFileSync(path.join(prepared, "RELEASE-MANIFEST.sha256"), manifestFor(prepared, completeRelatives));
  assert.equal(session.hotReloadCompatibility(config(), prepared).compatible, false,
    "a semantic PowerShell runtime change must still require restart");
  fs.writeFileSync(candidateScript, "Write-Output one\nWrite-Output two\n");
  fs.writeFileSync(path.join(prepared, "RELEASE-MANIFEST.sha256"), manifestFor(prepared, completeRelatives));

  fs.writeFileSync(path.join(prepared, "RELEASE-MANIFEST.sha256"), manifestFor(prepared, [coldRelative, scriptRelative]));
  assert.equal(session.hotReloadCompatibility(config(), prepared).compatible, false, "a protected file removal must require restart");
  fs.writeFileSync(path.join(prepared, "RELEASE-MANIFEST.sha256"), manifestFor(prepared, completeRelatives));
  fs.writeFileSync(path.join(installRoot, ...coldRelative.split("/")), "changed");
  const incompatible = session.hotReloadCompatibility(config(), prepared);
  assert.equal(incompatible.compatible, false);
  assert.match(incompatible.reason, /CodexRemoteSimple/u);
}

async function testCancelDuringPrepare() {
  let finishPrepare;
  const h = harness({ prepare: async (actual, directory, retained) => new Promise((resolve) => {
    finishPrepare = () => resolve({ prepared: true, preparedPath: retained, version: actual.version, archiveSha256: actual.archiveSha256 });
  }) });
  await h.controller.check(true);
  await h.controller.queue();
  await h.controller.cancel();
  const immediate = await h.controller.queue();
  assert.equal(immediate.canQueue, false, "Cancel followed immediately by Queue must wait for preparation cleanup");
  finishPrepare();
  await waitOperation(h.controller);
  assert.equal(h.calls.close, 0);
  assert.equal(h.calls.apply, 0);
  assert.equal(h.controller.status.state, "available");
  assert.equal(h.controller.status.canQueue, true);
  assert.ok(h.controller.history.some(entry => entry.state === "cancelled"));
}

async function testDuplicateQueueGuard() {
  const h = harness();
  await h.controller.check(true);
  await Promise.all([
    h.controller.request("queue", "same-id"),
    h.controller.request("queue", "same-id"),
    h.controller.request("queue", "other-id"),
  ]);
  await waitOperation(h.controller);
  assert.equal(h.calls.prepare, 1);
  assert.equal(h.calls.close, 1);
}

async function testCloseRefusal() {
  const h = harness({ closeResult: false });
  await h.controller.check(true);
  await h.controller.queue();
  await waitOperation(h.controller);
  assert.equal(h.calls.close, 1);
  assert.equal(h.calls.apply, 0);
  assert.equal(h.calls.relaunch, 0);
  assert.equal(h.controller.status.state, "error");
  assert.equal(h.controller.stopping, false);
  assert.deepEqual(h.calls.closingExpected, [true, false], "a refused close must re-enable unexpected-disconnect recovery");
}

async function testMonitorSingleflightAndCadence() {
  let finishProbe;
  const h = harness({ probe: () => new Promise((resolve) => { finishProbe = resolve; }) });
  h.controller.config.identityProbeIntervalMs = 0;
  const first = h.controller.monitorApp();
  const second = h.controller.monitorApp();
  await Promise.resolve();
  assert.equal(h.calls.probe, 1, "concurrent monitor ticks must share one strict native probe");
  finishProbe(true);
  assert.deepEqual(await Promise.all([first, second]), [true, true]);

  h.controller.config.identityProbeIntervalMs = 60_000;
  await h.controller.monitorApp();
  await h.controller.monitorApp();
  assert.equal(h.calls.probe, 1, "the 60-second cadence must suppress redundant strict probes");
  assert.equal(h.calls.isAlive, 3, "each effective monitor pass must retain the cheap PID liveness check");

  const dead = harness({ alive: false });
  assert.equal(await dead.controller.monitorApp(), false);
  assert.equal(dead.calls.probe, 0, "a failed cheap liveness check must stop before a native probe");
}

function testMalformedOwnerLockFailsClosed() {
  const cfg = config({ app: { pid: 987654, startTimeFileTimeUtc: "134000000000000001", executablePath: path.join(tempRoot, "ChatGPT.exe") } });
  const initial = session.acquireLock(cfg);
  assert.equal(initial.acquired, true);
  fs.rmSync(initial.lockPath, { force: true });
  fs.writeFileSync(initial.lockPath, "{malformed\n", { encoding: "utf8", mode: 0o600 });
  const malformed = session.acquireLock(cfg);
  assert.equal(malformed.acquired, false, "a malformed existing lock owner must fail closed");
  assert.equal(fs.readFileSync(initial.lockPath, "utf8"), "{malformed\n", "a malformed lock must not be removed or replaced");
  fs.rmSync(initial.lockPath, { force: true });
}

async function testDeadLegacyPidOnlyLockReclaimed() {
  const cfg = config({ app: { pid: 987656, startTimeFileTimeUtc: "134000000000000003", executablePath: path.join(tempRoot, "ChatGPT.exe") } });
  const initial = session.acquireLock(cfg);
  assert.equal(initial.acquired, true);
  fs.rmSync(initial.lockPath, { force: true });
  const deadOwner = spawn(process.execPath, ["-e", "process.exit(0)"], { stdio: "ignore", windowsHide: true });
  const deadPid = deadOwner.pid;
  await events.once(deadOwner, "close");
  fs.writeFileSync(initial.lockPath, `${JSON.stringify({ pid: deadPid })}\n`, { encoding: "utf8", mode: 0o600 });
  delete cfg.coordinatorProcessIdentity;
  const reclaimed = session.acquireLock(cfg);
  assert.equal(reclaimed.acquired, true, "a dead v1.5.83 PID-only lock must be reclaimed automatically");
  fs.rmSync(initial.lockPath, { force: true });
}

function testAtomicHandoffResultRetriesTransientRename() {
  const resultPath = path.join(sessionDirectory, "atomic-handoff-result.json");
  const originalRename = fs.renameSync;
  let attempts = 0;
  fs.renameSync = (source, destination) => {
    if (destination === resultPath && attempts++ < 2) {
      const error = new Error("transient scanner lock");
      error.code = "EPERM";
      throw error;
    }
    return originalRename(source, destination);
  };
  try {
    handoffHelper.atomicResult(resultPath, { started: true });
    assert.deepEqual(JSON.parse(fs.readFileSync(resultPath, "utf8")), { started: true });
    assert.equal(attempts, 3);
  } finally {
    fs.renameSync = originalRename;
    fs.rmSync(resultPath, { force: true });
  }
}

async function testConcurrentStaleLockReclamation() {
  const cfg = config({ app: { pid: 987655, startTimeFileTimeUtc: "134000000000000002", executablePath: path.join(tempRoot, "ChatGPT.exe") } });
  const initial = session.acquireLock(cfg);
  assert.equal(initial.acquired, true);
  fs.rmSync(initial.lockPath, { force: true });

  const deadOwner = spawn(process.execPath, ["-e", "setTimeout(() => process.exit(0), 1500)"], { stdio: "ignore", windowsHide: true });
  const deadPid = deadOwner.pid;
  const deadIdentity = session.queryCoordinatorProcessIdentity(deadPid, process.platform);
  assert.ok(deadIdentity, "the stale fixture owner must have an exact process identity before exit");
  await events.once(deadOwner, "close");
  fs.writeFileSync(initial.lockPath, `${JSON.stringify(deadIdentity)}\n`, { encoding: "utf8", mode: 0o600 });

  const childSource = `
    const fs = require("node:fs");
    const { acquireLock, queryCoordinatorProcessIdentity } = require(process.argv[1]);
    const config = JSON.parse(Buffer.from(process.argv[2], "base64url").toString("utf8"));
    config.coordinatorProcessIdentity = queryCoordinatorProcessIdentity(process.pid, config.platform);
    if (!config.coordinatorProcessIdentity) throw new Error("fixture identity unavailable");
    fs.writeFileSync(process.argv[3] + "." + process.pid, "ready");
    const goDeadline = Date.now() + 30_000;
    while (!fs.existsSync(process.argv[3])) {
      if (fs.existsSync(process.argv[3] + "-abort")) process.exit(0);
      if (Date.now() >= goDeadline) throw new Error("fixture start signal not received");
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
    }
    const result = acquireLock(config);
    process.stdout.write(result.acquired ? "1" : "0");
    setTimeout(() => process.exit(0), result.acquired ? 5000 : 0);
  `;
  delete cfg.coordinatorProcessIdentity;
  const encodedConfig = Buffer.from(JSON.stringify(cfg), "utf8").toString("base64url");
  const goPath = path.join(tempRoot, `lock-contenders-go-${crypto.randomUUID()}`);
  const claims = Array.from({ length: 12 }, () => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["-e", childSource, windowsModulePath, encodedConfig, goPath], {
      stdio: ["ignore", "pipe", "pipe"], windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) reject(new Error(`Lock contender failed: ${stderr}`));
      else resolve(stdout);
    });
  }));
  const settledClaims = Promise.all(claims);
  let contenderFailure = null;
  settledClaims.catch((error) => { contenderFailure = error; });
  let results;
  try {
    const readyDeadline = Date.now() + 20_000;
    while (!contenderFailure && fs.readdirSync(tempRoot).filter((name) => name.startsWith(path.basename(goPath) + ".")).length < 12 && Date.now() < readyDeadline) {
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    if (contenderFailure) throw contenderFailure;
    assert.equal(fs.readdirSync(tempRoot).filter((name) => name.startsWith(path.basename(goPath) + ".")).length, 12,
      "all lock contenders must establish their own identity before the simultaneous claim");
    fs.writeFileSync(goPath, "go");
    results = await settledClaims;
  } catch (error) {
    try { fs.writeFileSync(`${goPath}-abort`, "abort"); } catch {}
    await Promise.allSettled(claims);
    throw error;
  }
  assert.equal(results.filter((value) => value === "1").length, 1, "concurrent stale-lock reclaimers must produce exactly one helper owner");
  fs.rmSync(initial.lockPath, { force: true });
  fs.rmSync(`${initial.lockPath}.reclaim`, { force: true, recursive: true });
}

async function testTimedOutCommandTreeLeavesNoMutation() {
  const marker = path.join(tempRoot, `late-mutation-${crypto.randomUUID()}`);
  const descendantSource = `setTimeout(() => require("node:fs").writeFileSync(process.argv[1], "late"), 900); setTimeout(() => {}, 10000);`;
  const parentSource = `require("node:child_process").spawn(process.execPath, ["-e", ${JSON.stringify(descendantSource)}, process.argv[1]], { stdio:"ignore", windowsHide:true }); setTimeout(() => {}, 10000);`;
  await assert.rejects(
    session.runCommand(process.execPath, ["-e", parentSource, marker], { cwd: tempRoot, timeoutMs: 200 }),
    /timed out after 200 milliseconds/u,
  );
  await new Promise((resolve) => setTimeout(resolve, 1300));
  assert.equal(fs.existsSync(marker), false, "a timed-out owned command tree must not mutate state after rejection");
}

async function testUnsafeApplyRecoversAndRelaunchesOnce() {
  const h = harness({ applyError: new Error("UNSAFE_MIXED_INSTALL: simulated interruption") });
  await h.controller.check(true);
  await h.controller.queue();
  await waitOperation(h.controller);
  assert.equal(h.calls.recover, 1, "UNSAFE_MIXED_INSTALL must invoke journal recovery");
  assert.equal(h.calls.relaunch, 1, "a recovered install must relaunch exactly once");
  assert.equal(h.calls.notify, 1);
  assert.equal(h.controller.stopping, true);
}

async function testRecoveryFailureRetainsPrepared() {
  const h = harness({ applyError: new Error("UNSAFE_MIXED_INSTALL"), recoverError: new Error("journal remains") });
  await h.controller.check(true);
  await h.controller.queue();
  await waitOperation(h.controller);
  assert.equal(h.calls.relaunch, 0);
  assert.equal(h.calls.notify, 1);
  assert.equal(h.calls.removed.includes(h.retained), false, "unresolved recovery must retain the prepared payload");
}

async function testUnverifiedTimeoutBlocksRecovery() {
  const timeout = new Error("owned process tree could not be proven stopped");
  timeout.commandTreeTerminationUnverified = true;
  const h = harness({ applyError: timeout });
  await h.controller.check(true);
  await h.controller.queue();
  await waitOperation(h.controller);
  assert.equal(h.calls.recover, 0, "recovery must not race a command tree that may still be mutating the install");
  assert.equal(h.calls.relaunch, 0, "an install with an unverified updater tree must remain closed");
  assert.equal(h.calls.removed.includes(h.retained), false, "the prepared payload must be retained for manual recovery");
}

async function testSecondPreflightBlocksClose() {
  let writableCalls = 0;
  const h = harness();
  h.controller.isWritable = () => { writableCalls += 1; return writableCalls === 1; };
  await h.controller.check(true);
  await h.controller.queue();
  await waitOperation(h.controller);
  assert.equal(h.calls.close, 0);
  assert.equal(h.controller.status.state, "unavailable");
}

async function testExactRelaunchArguments() {
  const cfg = config();
  cfg.configPath = path.join(sessionDirectory, "session.json");
  let invocation;
  const fakeSpawn = (command, args, options) => {
    invocation = { command, args, options };
    const child = new events.EventEmitter();
    child.pid = 999;
    child.exitCode = null;
    child.unref = () => {};
    setImmediate(() => {
      fs.writeFileSync(path.join(sessionDirectory, "relaunch-handoff.json"), JSON.stringify({ ready: true, entryPointRelative: cfg.relaunch.entryPointRelative }));
      child.emit("spawn");
    });
    return child;
  };
  const adapter = new session.PlatformAdapter(cfg, { spawn: fakeSpawn });
  await adapter.relaunch();
  assert.ok(invocation.args.includes("-UpdateResume"));
  assert.ok(invocation.args.includes("-SkipDesktopAppUpdateOnce"), "update-session relaunch must not repeat the already completed desktop-app gate");
  assert.ok(invocation.args.includes("-SkipUpdateCheckOnce"));
  assert.equal(invocation.args.includes("-ReplaceRunningApp"), false, "update resume must never replace a process that appeared during update");
  assert.ok(invocation.args.includes("-UseProxy"), "saved protected-proxy mode must be reloaded by the updated launcher");
  assert.equal(invocation.args.some((value) => /https?:\/\//u.test(value)), false, "relaunch args must not persist proxy credentials or URLs");
  assert.equal(invocation.options.detached, false, "Windows PowerShell must execute in the coordinator process group so its script is not skipped");
  assert.equal(invocation.options.windowsHide, true, "Windows relaunch must remain hidden");
}

async function testCoordinatorHandoffSchedule() {
  const cfg = config();
  cfg.configPath = path.join(sessionDirectory, "session.json");
  cfg.coordinatorLockPath = path.join(stateRoot, "active", "fixture.lock");
  let invocation;
  const fakeSpawn = (command, args, options) => {
    invocation = { command, args, options };
    const child = new events.EventEmitter();
    child.pid = 1001;
    child.unref = () => {};
    setImmediate(() => {
      child.emit("spawn");
      const handoff = JSON.parse(fs.readFileSync(args[2], "utf8"));
      fs.writeFileSync(handoff.resultPath, JSON.stringify({ attemptId: handoff.attemptId, armed: true, started: false }));
      const release = handoff.releasePath;
      const poll = setInterval(() => {
        if (!fs.existsSync(release)) return;
        clearInterval(poll);
        fs.writeFileSync(handoff.resultPath, JSON.stringify({ attemptId: handoff.attemptId, started: true, readySession: path.join(stateRoot, "sessions", "replacement") }));
      }, 5);
    });
    return child;
  };
  let released = false;
  let quiesced = false;
  const adapter = new session.PlatformAdapter(cfg, {
    spawn: fakeSpawn,
    quiesceCoordinatorTransport: async () => { quiesced = true; },
    restoreCoordinatorTransport: async () => { quiesced = false; },
    releaseCoordinatorLock: () => { released = true; },
    reacquireCoordinatorLock: () => { released = false; },
    coordinatorLockOwned: () => !released,
  });
  const result = await adapter.handoffCoordinator();
  assert.equal(result.activated, true);
  assert.equal(released, true);
  assert.equal(quiesced, true, "the predecessor transport must remain quiesced after the successor proves readiness");
  assert.equal(invocation.command, process.execPath);
  assert.equal(path.basename(invocation.args[1]), "coordinator-handoff.js");
  assert.equal(invocation.options.detached, true);
  assert.equal(invocation.options.windowsHide, true);
  const handoff = JSON.parse(fs.readFileSync(invocation.args[2], "utf8"));
  assert.match(handoff.attemptId, /^[a-f0-9]{32}$/u);
  assert.equal(handoff.previousPid, process.pid);
  assert.equal(handoff.lockPath, cfg.coordinatorLockPath);
  assert.equal(handoff.stateRoot, cfg.stateRoot);
  assert.equal(handoff.previousSessionDirectory, cfg.sessionDirectory);
  assert.equal(handoff.entryPointRelative, cfg.relaunch.entryPointRelative);
  assert.equal(handoff.useProxy, true);
  assert.equal(handoff.replaceRunningApp, true);
}

async function testCoordinatorHandoffFailureReclaimsLock() {
  const cfg = config();
  cfg.configPath = path.join(sessionDirectory, "session.json");
  cfg.coordinatorLockPath = path.join(stateRoot, "active", "fixture.lock");
  const fakeSpawn = (_command, args) => {
    const child = new events.EventEmitter();
    child.pid = 1002;
    child.unref = () => {};
    setImmediate(() => {
      child.emit("spawn");
      const handoff = JSON.parse(fs.readFileSync(args[2], "utf8"));
      fs.writeFileSync(handoff.resultPath, JSON.stringify({ attemptId: handoff.attemptId, armed: true, started: false }));
      const release = handoff.releasePath;
      const poll = setInterval(() => {
        if (!fs.existsSync(release)) return;
        clearInterval(poll);
        fs.writeFileSync(handoff.resultPath, JSON.stringify({ attemptId: handoff.attemptId, started: false, reason: "fixture-replacement-failed" }));
      }, 5);
    });
    return child;
  };
  let released = false;
  let reacquired = false;
  let quiesced = false;
  let restored = false;
  const adapter = new session.PlatformAdapter(cfg, {
    spawn: fakeSpawn,
    quiesceCoordinatorTransport: async () => { quiesced = true; },
    restoreCoordinatorTransport: async () => { quiesced = false; restored = true; },
    releaseCoordinatorLock: () => { released = true; },
    reacquireCoordinatorLock: () => { reacquired = true; released = false; },
    coordinatorLockOwned: () => !released,
  });
  await assert.rejects(adapter.handoffCoordinator(), /fixture-replacement-failed/u);
  assert.equal(reacquired, true, "a failed successor must return lock ownership to the still-running predecessor");
  assert.equal(released, false);
  assert.equal(restored, true, "a failed successor must reattach and republish the predecessor transport");
  assert.equal(quiesced, false);
}

function testCoordinatorHandoffConfigBoundary() {
  const attemptId = "a".repeat(32);
  const configPath = path.join(sessionDirectory, `coordinator-handoff-${attemptId}.json`);
  const launcherPath = path.join(installRoot, "CodexRemoteMobileProject", "UpdateSessionLauncher.ps1");
  fs.mkdirSync(path.dirname(launcherPath), { recursive: true });
  fs.writeFileSync(launcherPath, "fixture");
  const priorConfig = config();
  priorConfig.app = { pid: 7654, startTimeFileTimeUtc: "134000000000000000", executablePath: "C:\\Program Files\\ChatGPT\\ChatGPT.exe" };
  fs.writeFileSync(path.join(sessionDirectory, "session.json"), JSON.stringify(priorConfig));
  fs.writeFileSync(priorConfig.platformHelperPath, "fixture");
  const value = {
    attemptId, platform: "win32", previousPid: 4321, appPid: 7654, app: priorConfig.app, installRoot,
    stateRoot, previousSessionDirectory: sessionDirectory, expectedVersion: "v1.5.84",
    configPath: path.join(sessionDirectory, "session.json"), platformHelperPath: priorConfig.platformHelperPath,
    lockPath: path.join(stateRoot, "active", "fixture.lock"),
    resultPath: path.join(sessionDirectory, `coordinator-handoff-result-${attemptId}.json`),
    releasePath: path.join(sessionDirectory, `coordinator-handoff-release-${attemptId}.json`),
    nodePath: process.execPath, launcherPath,
  };
  assert.equal(handoffHelper.exactChildConfig({ ...value }, configPath).launcherPath, launcherPath);
  assert.throws(() => handoffHelper.exactChildConfig({ ...value, resultPath: path.join(tempRoot, "outside.json") }, configPath), /outside its session/u);
  assert.throws(() => handoffHelper.exactChildConfig({ ...value, launcherPath: path.join(tempRoot, "other.ps1") }, configPath), /launcher is unavailable/u);
  const modulePath = handoffHelper.windowsPowerShellModulePath({
    USERPROFILE: "C:\\Users\\fixture", ProgramFiles: "C:\\Program Files", SystemRoot: "C:\\Windows",
    PSModulePath: "C:\\Program Files\\PowerShell\\7\\Modules",
  });
  assert.match(modulePath, /WindowsPowerShell\\Modules/u);
  assert.doesNotMatch(modulePath, /PowerShell\\7/u);
  assert.equal(handoffHelper.sameAppIdentity(value.app, { ...value.app }, "win32"), true);
  assert.equal(handoffHelper.sameAppIdentity(value.app, { ...value.app, startTimeFileTimeUtc: "134000000000000001" }, "win32"), false,
    "PID reuse with a different creation time must terminate handoff");
  const coordinatorIdentity = { pid: 1234, startToken: "134000000000000000", executablePath: process.execPath };
  assert.equal(handoffHelper.sameCoordinatorProcessIdentity(coordinatorIdentity, { ...coordinatorIdentity }, "win32"), true);
  assert.equal(handoffHelper.sameCoordinatorProcessIdentity(coordinatorIdentity,
    { ...coordinatorIdentity, startToken: "134000000000000001" }, "win32"), false,
  "PID reuse with a different coordinator creation time must never authorize candidate cleanup");
  const macCoordinator = { pid: 1234, startToken: "Sat Sep 5 12:00:00 2026", executablePath: "/opt/homebrew/Cellar/node/22/bin/node" };
  assert.equal(handoffHelper.sameCoordinatorProcessIdentity(macCoordinator,
    { ...macCoordinator, executablePath: "/opt/homebrew/bin/node" }, "darwin"), true,
  "macOS coordinator identity must tolerate a launcher symlink while retaining PID and start-token proof");
}

async function testExactMacRelaunchArguments() {
  const cfg = config({
    platform: "darwin",
    updaterPath: path.join(bundleRoot, "Update-ChatGPTRemote.sh"),
    platformHelperPath: path.join(bundleRoot, "UpdateSessionPlatform.sh"),
    app: { pid: 4321, startToken: "Sat Sep  5 12:00:00 2026", executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", appPath: "/Applications/ChatGPT.app", bundleId: "com.example.ChatGPT" },
    relaunch: { entryPointRelative: "MobileProjectView-macOS-arm64.sh", startupMode: true },
  });
  cfg.configPath = path.join(sessionDirectory, "session.json");
  let invocation;
  const fakeSpawn = (command, args, options) => {
    invocation = { command, args, options };
    const child = new events.EventEmitter();
    child.pid = 1000;
    child.exitCode = null;
    child.unref = () => {};
    setImmediate(() => {
      fs.writeFileSync(path.join(sessionDirectory, "relaunch-handoff.json"), JSON.stringify({ ready: true, entryPointRelative: cfg.relaunch.entryPointRelative }));
      child.emit("spawn");
    });
    return child;
  };
  const adapter = new session.PlatformAdapter(cfg, { spawn: fakeSpawn });
  await adapter.relaunch();
  assert.equal(invocation.command, "/bin/zsh");
  assert.deepEqual(invocation.args, [path.join(cfg.installRoot, cfg.relaunch.entryPointRelative), "startup"]);
  assert.equal(invocation.options.env.CODEX_REMOTE_SKIP_UPDATE_CHECK_ONCE, "1");
  assert.equal(invocation.options.env.CODEX_REMOTE_SKIP_PRELAUNCH_UPDATE_ONCE, "1", "a detached relaunch must not run a second prelaunch update");
  assert.equal(invocation.options.env.CODEX_REMOTE_SKIP_STARTUP_DELAY_ONCE, "1");
  assert.equal(invocation.options.detached, true);
  assert.equal(invocation.options.windowsHide, true);
}

async function testUpdaterMappingsAndPrettyJson() {
  const cfg = config({ platform: "darwin", updaterPath: path.join(bundleRoot, "Update-ChatGPTRemote.sh"), platformHelperPath: path.join(bundleRoot, "UpdateSessionPlatform.sh"),
    app: { pid: 4321, startToken: "Sat Sep  5 12:00:00 2026", executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", appPath: "/Applications/ChatGPT.app", bundleId: "com.example.ChatGPT" },
    relaunch: { entryPointRelative: "MobileProjectView-macOS-arm64.sh" } });
  const invocations = [];
  const adapter = new session.UpdaterAdapter(cfg, { runCommand: async (command, args) => {
    invocations.push({ command, args });
    return { stdout: '{\n  "updated": true,\n  "version": "v1.5.32"\n}\n', stderr: "" };
  } });
  await adapter.applyPrepared({ version: "v1.5.32", archiveSha256: "b".repeat(64) }, path.join(sessionDirectory, "prepared", "v1.5.32"));
  assert.equal(invocations[0].args[1], "apply-prepared");
}

async function testProductionRendererReadinessContract() {
  const injector = path.join(installRoot, "CodexRemoteMobileProject", "inject.js");
  fs.mkdirSync(path.dirname(injector), { recursive: true });
  fs.writeFileSync(injector, "// fixture injector\n");
  fs.writeFileSync(path.join(installRoot, "VERSION"), "v2.0.0\n");
  const invocations = [];
  const adapter = new session.PlatformAdapter(config(), { runCommand: async (command, args) => {
    invocations.push({ command, args });
    if (command === process.execPath) {
      return { stdout: `${JSON.stringify({ ok: true, report: { active: true, version: 82, readiness: { ready: true } } })}\n`, stderr: "" };
    }
    return { stdout: '{"running":true}\n', stderr: "" };
  } });
  try {
    const result = await adapter.hotReload({ version: "v2.0.0" });
    assert.deepEqual(result, { loaded: true, helperVersion: "v2.0.0", rendererVersion: 82, ready: true });
    assert.equal(invocations.filter(item => item.command === process.execPath).length, 1,
      "production-shaped nested readiness must complete on the enable proof");
  } finally {
    fs.writeFileSync(path.join(installRoot, "VERSION"), "v1.0.0\n");
  }
}

async function testMacHotReloadIdentityArguments() {
  const cfg = config({
    platform: "darwin",
    updaterPath: path.join(bundleRoot, "Update-ChatGPTRemote.sh"),
    platformHelperPath: path.join(bundleRoot, "UpdateSessionPlatform.sh"),
    app: { pid: 4321, startToken: "Sat Sep  5 12:00:00 2026", executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", appPath: "/Applications/ChatGPT.app", bundleId: "com.example.ChatGPT" },
    relaunch: { entryPointRelative: "MobileProjectView-macOS-arm64.sh", environment: { CODEX_REMOTE_LOCAL_NAME: "MacBook-Pro", CODEX_REMOTE_PEER_NAME: "Windows-VM" } },
  });
  const injector = path.join(installRoot, "inject.js");
  fs.writeFileSync(injector, "// fixture injector\n");
  fs.writeFileSync(path.join(installRoot, "VERSION"), "v2.0.0\n");
  let invocation;
  const adapter = new session.PlatformAdapter(cfg, { runCommand: async (command, args) => {
    if (command === process.execPath) {
      invocation = { command, args };
      return { stdout: `${JSON.stringify({ ok: true, report: { active: true, version: 82, readiness: { ready: true } } })}\n`, stderr: "" };
    }
    return { stdout: '{"running":true}\n', stderr: "" };
  } });
  try {
    await adapter.hotReload({ version: "v2.0.0" });
    assert.equal(invocation.args[invocation.args.indexOf("--local-name") + 1], "MacBook-Pro");
    assert.equal(invocation.args[invocation.args.indexOf("--single-remote-name") + 1], "Windows-VM");
  } finally {
    fs.rmSync(injector, { force: true });
    fs.writeFileSync(path.join(installRoot, "VERSION"), "v1.0.0\n");
  }
}

function testMacLauncherCaptureIdentity() {
  const source = fs.readFileSync(path.join(root, "macos", "MobileProjectView-macOS-arm64.sh"), "utf8");
  assert.doesNotMatch(source, /capture_exact_app_identity/u, "the coordinator-only macOS path must call the defined identity capture function");
  assert.match(source, /identity="\$\(capture_app_identity\)"/u);
  assert.match(source, /CODEX_REMOTE_LOCAL_NAME:localName/u, "new macOS coordinators must retain the actual local computer name");
}

async function testActualWindowsCheck() {
  if (process.platform !== "win32" || process.argv.includes("--skip-actual-updater")) return;
  const archiveSha256 = crypto.createHash("sha256").update("fixture archive").digest("hex");
  const server = http.createServer((request, response) => {
    const port = server.address().port;
    if (request.url === "/release.json") {
      response.setHeader("Content-Type", "application/json");
      response.end(JSON.stringify({ draft: false, prerelease: false, tag_name: "v9.8.7", assets: [
        { name: "ChatGPT-Remote-Enabler-Windows-x64-v9.8.7.zip", browser_download_url: `http://127.0.0.1:${port}/archive.zip` },
        { name: "SHA256SUMS-v9.8.7.txt", browser_download_url: `http://127.0.0.1:${port}/sums.txt` },
      ] }));
    } else if (request.url === "/sums.txt") {
      response.end(`${archiveSha256} *ChatGPT-Remote-Enabler-Windows-x64-v9.8.7.zip\n`);
    } else {
      response.statusCode = 404;
      response.end();
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const previousTransport = process.env.CHATGPT_REMOTE_UPDATE_TRANSPORT;
  process.env.CHATGPT_REMOTE_UPDATE_TRANSPORT = 'release';
  const previousLatest = process.env.CHATGPT_REMOTE_UPDATE_LATEST_URL;
  const previousInsecure = process.env.CHATGPT_REMOTE_UPDATE_ALLOW_INSECURE;
  process.env.CHATGPT_REMOTE_UPDATE_LATEST_URL = `http://127.0.0.1:${server.address().port}/release.json`;
  process.env.CHATGPT_REMOTE_UPDATE_ALLOW_INSECURE = "1";
  try {
    const cfg = config({ updaterPath: path.join(root, "windows", "Update-ChatGPTRemote.ps1"), relaunch: { ...config().relaunch, useProxy: false } });
    const adapter = new session.UpdaterAdapter(cfg);
    const result = await adapter.check();
    assert.equal(result.available, true);
    assert.equal(result.latestVersion, "v9.8.7");
    assert.equal(result.archiveSha256, archiveSha256);
  } finally {
    if (previousTransport === undefined) delete process.env.CHATGPT_REMOTE_UPDATE_TRANSPORT;
    else process.env.CHATGPT_REMOTE_UPDATE_TRANSPORT = previousTransport;
    if (previousLatest === undefined) delete process.env.CHATGPT_REMOTE_UPDATE_LATEST_URL;
    else process.env.CHATGPT_REMOTE_UPDATE_LATEST_URL = previousLatest;
    if (previousInsecure === undefined) delete process.env.CHATGPT_REMOTE_UPDATE_ALLOW_INSECURE;
    else process.env.CHATGPT_REMOTE_UPDATE_ALLOW_INSECURE = previousInsecure;
    await new Promise((resolve) => server.close(resolve));
  }
}

(async () => {
  try {
    testPersistentHistory();
    await testReadOnlyHistoryRefresh();
    await testPinnedIdleFlow();
    await testPinnedHotReloadFlow();
    await testCoordinatorActivationFailureKeepsAppOpen();
    await testIncompleteHandoffRecoveryStopsRetries();
    testCoordinatorAwareRetention();
    await testHotReloadFailureKeepsAppOpen();
    await testHotApplyFailureRestoresPriorRenderer();
    testHotReloadCompatibility();
    await testCancelDuringPrepare();
    await testDuplicateQueueGuard();
    await testCloseRefusal();
    await testUnsafeApplyRecoversAndRelaunchesOnce();
    await testRecoveryFailureRetainsPrepared();
    await testUnverifiedTimeoutBlocksRecovery();
    await testSecondPreflightBlocksClose();
    await testMonitorSingleflightAndCadence();
    testMalformedOwnerLockFailsClosed();
    await testDeadLegacyPidOnlyLockReclaimed();
    testAtomicHandoffResultRetriesTransientRename();
    await testConcurrentStaleLockReclamation();
    await testTimedOutCommandTreeLeavesNoMutation();
    await testExactRelaunchArguments();
    await testCoordinatorHandoffSchedule();
    await testCoordinatorHandoffFailureReclaimsLock();
    testCoordinatorHandoffConfigBoundary();
    await testExactMacRelaunchArguments();
    await testUpdaterMappingsAndPrettyJson();
    await testProductionRendererReadinessContract();
    await testMacHotReloadIdentityArguments();
    testMacLauncherCaptureIdentity();
    await testActualWindowsCheck();
    process.stdout.write(`${JSON.stringify({ ok: true, persistentHistory: true, controllerFlows: 13, monitorSingleflight: true, malformedLockFailClosed: true, concurrentLockReclaim: true, timeoutTreeContained: true, exactRelaunch: true, exactMacRelaunchSkipsPrelaunch: true, prettyJson: true, actualWindowsCheck: process.platform === "win32" && !process.argv.includes("--skip-actual-updater") })}\n`);
  } finally {
    fs.rmSync(tempRoot, { force: true, recursive: true });
  }
})().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
