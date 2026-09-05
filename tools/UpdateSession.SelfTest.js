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
  const calls = { apply: 0, check: 0, close: 0, closingExpected: [], isAlive: 0, notify: 0, prepare: 0, probe: 0, recover: 0, relaunch: 0, removed: [] };
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
    async relaunch() { calls.relaunch += 1; if (options.relaunchError) throw options.relaunchError; return { ready: true }; },
    async notifyFailure() { calls.notify += 1; },
  };
  const controller = new session.UpdateSessionController(config(), {
    transport,
    updater,
    platform,
    sleep: async () => {},
    isWritable: () => options.writable !== false,
    removePrepared: (directory) => calls.removed.push(directory),
  });
  return { activities, calls, controller, release, statuses, retained };
}

async function waitOperation(controller) {
  while (controller.queueRequestPromise) await controller.queueRequestPromise;
  if (controller.operationPromise) await controller.operationPromise;
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
  assert.ok(h.statuses.some((value) => value.state === "queued" && /Inventory/u.test(value.message)));
  assert.ok(h.statuses.some((value) => value.state === "closing" && value.canCancel === false));
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

async function testConcurrentStaleLockReclamation() {
  const cfg = config({ app: { pid: 987655, startTimeFileTimeUtc: "134000000000000002", executablePath: path.join(tempRoot, "ChatGPT.exe") } });
  const initial = session.acquireLock(cfg);
  assert.equal(initial.acquired, true);
  fs.rmSync(initial.lockPath, { force: true });

  const deadOwner = spawn(process.execPath, ["-e", "process.exit(0)"], { stdio: "ignore", windowsHide: true });
  const deadPid = deadOwner.pid;
  await events.once(deadOwner, "close");
  fs.writeFileSync(initial.lockPath, `${JSON.stringify({ pid: deadPid })}\n`, { encoding: "utf8", mode: 0o600 });

  const childSource = `
    const { acquireLock } = require(process.argv[1]);
    const config = JSON.parse(Buffer.from(process.argv[2], "base64url").toString("utf8"));
    const result = acquireLock(config);
    process.stdout.write(result.acquired ? "1" : "0");
    setTimeout(() => process.exit(0), result.acquired ? 1500 : 0);
  `;
  const encodedConfig = Buffer.from(JSON.stringify(cfg), "utf8").toString("base64url");
  const claims = Array.from({ length: 12 }, () => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["-e", childSource, windowsModulePath, encodedConfig], {
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
  const results = await Promise.all(claims);
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
  assert.ok(invocation.args.includes("-SkipUpdateCheckOnce"));
  assert.equal(invocation.args.includes("-ReplaceRunningApp"), false, "update resume must never replace a process that appeared during update");
  assert.ok(invocation.args.includes("-UseProxy"), "saved protected-proxy mode must be reloaded by the updated launcher");
  assert.equal(invocation.args.some((value) => /https?:\/\//u.test(value)), false, "relaunch args must not persist proxy credentials or URLs");
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
  const previousLatest = process.env.CHATGPT_REMOTE_UPDATE_LATEST_URL;
  const previousInsecure = process.env.CHATGPT_REMOTE_UPDATE_ALLOW_INSECURE;
  process.env.CHATGPT_REMOTE_UPDATE_LATEST_URL = `http://127.0.0.1:${server.address().port}/release.json`;
  process.env.CHATGPT_REMOTE_UPDATE_ALLOW_INSECURE = "1";
  try {
    const cfg = config({ updaterPath: path.join(root, "windows", "Update-ChatGPTRemote.ps1") });
    const adapter = new session.UpdaterAdapter(cfg);
    const result = await adapter.check();
    assert.equal(result.available, true);
    assert.equal(result.latestVersion, "v9.8.7");
    assert.equal(result.archiveSha256, archiveSha256);
  } finally {
    if (previousLatest === undefined) delete process.env.CHATGPT_REMOTE_UPDATE_LATEST_URL;
    else process.env.CHATGPT_REMOTE_UPDATE_LATEST_URL = previousLatest;
    if (previousInsecure === undefined) delete process.env.CHATGPT_REMOTE_UPDATE_ALLOW_INSECURE;
    else process.env.CHATGPT_REMOTE_UPDATE_ALLOW_INSECURE = previousInsecure;
    await new Promise((resolve) => server.close(resolve));
  }
}

(async () => {
  try {
    await testPinnedIdleFlow();
    await testCancelDuringPrepare();
    await testDuplicateQueueGuard();
    await testCloseRefusal();
    await testUnsafeApplyRecoversAndRelaunchesOnce();
    await testRecoveryFailureRetainsPrepared();
    await testUnverifiedTimeoutBlocksRecovery();
    await testSecondPreflightBlocksClose();
    await testMonitorSingleflightAndCadence();
    testMalformedOwnerLockFailsClosed();
    await testConcurrentStaleLockReclamation();
    await testTimedOutCommandTreeLeavesNoMutation();
    await testExactRelaunchArguments();
    await testUpdaterMappingsAndPrettyJson();
    await testActualWindowsCheck();
    process.stdout.write(`${JSON.stringify({ ok: true, controllerFlows: 8, monitorSingleflight: true, malformedLockFailClosed: true, concurrentLockReclaim: true, timeoutTreeContained: true, exactRelaunch: true, prettyJson: true, actualWindowsCheck: process.platform === "win32" && !process.argv.includes("--skip-actual-updater") })}\n`);
  } finally {
    fs.rmSync(tempRoot, { force: true, recursive: true });
  }
})().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
