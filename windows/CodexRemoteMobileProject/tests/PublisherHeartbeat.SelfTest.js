"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const childProcess = require("node:child_process");
const windowsPublisher = require("../publisher-heartbeat.js");
const macPublisher = require(path.resolve(__dirname, "..", "..", "..", "macos", "publisher-heartbeat.js"));
const {
  PUBLISHER_LOCK_PROTOCOL_VERSION,
  TARGET_URL,
  acquireLock,
  parseArgs,
  processMatches,
  processStartToken,
  publishLockAtomically,
  publisherLockParentState,
  publisherOwnerState,
  pulse,
  run,
} = windowsPublisher;

(async () => {
  assert.deepEqual(parseArgs(["--port", "1234", "--parent-pid", "5678", "--parent-start-token", "134000000000000000", "--interval-ms", "9000"]), {
    intervalMs: 9000, lockPath: null, parentPid: 5678, parentStartToken: "134000000000000000", port: 1234,
  });
  assert.throws(() => parseArgs(["--port", "0", "--parent-pid", "1", "--parent-start-token", "1"]), /renderer port/u);
  assert.throws(() => parseArgs(["--port", "1234", "--parent-pid", "1"]), /start token/u);
  if (process.platform === "win32") {
    const launcherToken = childProcess.execFileSync("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", `(Get-Process -Id ${process.pid} -ErrorAction Stop).StartTime.ToUniversalTime().ToFileTimeUtc()`], { encoding: "utf8", windowsHide: true }).trim();
    assert.equal(processStartToken(process.pid), launcherToken, "heartbeat must use the launcher's Windows FILETIME token format");
    assert.equal(processMatches(process.pid, launcherToken), true);
  }

  const lockRoot = fs.mkdtempSync(path.join(os.tmpdir(), "publisher-heartbeat-lock-"));
  const lockPath = path.join(lockRoot, "heartbeat.lock");
  try {
    const releaseOld = acquireLock(lockPath, 100, "old-start", 1234);
    assert.equal(typeof releaseOld, "function");
    assert.equal(releaseOld.owns(), true);
    const activeOwner = JSON.parse(fs.readFileSync(lockPath, "utf8"));
    assert.equal(activeOwner.protocolVersion, PUBLISHER_LOCK_PROTOCOL_VERSION);
    assert.equal(activeOwner.state, "active");
    assert.equal(activeOwner.publisherStartToken, processStartToken(process.pid));
    assert.equal(activeOwner.executablePath, path.resolve(process.execPath));
    assert.equal(activeOwner.scriptPath, path.resolve(__dirname, "..", "publisher-heartbeat.js"));
    assert.equal(acquireLock(lockPath, 100, "old-start", 1234), null, "same exact session must retain one helper");
    assert.equal(
      acquireLock(lockPath, 100, "new-start", 1234),
      null,
      "a live owner must remain fail-closed even when the renderer session differs",
    );
    releaseOld();
    const releaseNew = acquireLock(lockPath, 100, "new-start", 1234);
    assert.equal(typeof releaseNew, "function", "a successor must acquire ownership after the live owner releases it");
    releaseNew();
    assert.equal(fs.existsSync(lockPath), false);

    fs.writeFileSync(lockPath, `${JSON.stringify({
      parentPid: 100,
      parentStartToken: "new-start",
      pid: process.pid,
      port: 1234,
      protocolVersion: PUBLISHER_LOCK_PROTOCOL_VERSION,
      publisherStartToken: "1",
      state: "active",
      token: "a".repeat(48),
    })}\n`);
    const releaseReused = acquireLock(lockPath, 100, "new-start", 1234);
    assert.equal(typeof releaseReused, "function", "a v2 lock with a reused owner PID was not reclaimed");
    releaseReused();

    assert.equal(publisherOwnerState({
      pid: process.pid,
      protocolVersion: PUBLISHER_LOCK_PROTOCOL_VERSION,
      publisherStartToken: "1",
    }, { processMatches: () => null }), "unknown", "an uncertain v2 owner lookup must fail closed");
    assert.equal(publisherOwnerState({ pid: process.pid }, { processExists: () => true }), "alive");
    assert.equal(publisherOwnerState({ pid: process.pid }, { processExists: () => false }), "retired");

    fs.writeFileSync(lockPath, "{partial-handoff");
    assert.equal(acquireLock(lockPath, 100, "new-start", 1234), null, "a malformed ownership record must remain fail-closed");
    assert.equal(fs.readFileSync(lockPath, "utf8"), "{partial-handoff");
    fs.rmSync(lockPath, { force: true });

    fs.writeFileSync(lockPath, `${JSON.stringify({
      parentPid: 100,
      parentStartToken: "new-start",
      port: 1234,
      protocolVersion: PUBLISHER_LOCK_PROTOCOL_VERSION,
      state: "handoff",
      token: "guarded-handoff",
    })}\n`);
    assert.equal(
      acquireLock(lockPath, 100, "new-start", 1234),
      null,
      "a guarded handoff marker must never be removed or claimed by a successor",
    );
    assert.equal(JSON.parse(fs.readFileSync(lockPath, "utf8")).token, "guarded-handoff");

    const interruptedPath = path.join(lockRoot, "interrupted.lock");
    assert.throws(
      () => publishLockAtomically(interruptedPath, "complete-record\n", { beforeLink() { throw new Error("fixture interruption"); } }),
      /fixture interruption/u,
    );
    assert.equal(fs.existsSync(interruptedPath), false, "interruption before publication exposed a partial lock");
    assert.equal(fs.readdirSync(lockRoot).some((name) => name.includes(".create-") && name.endsWith(".tmp")), false);

    const competingPath = path.join(lockRoot, "competing.lock");
    fs.writeFileSync(competingPath, "competing-owner\n");
    assert.throws(
      () => publishLockAtomically(competingPath, "replacement-owner\n"),
      (error) => error?.code === "EEXIST",
    );
    assert.equal(fs.readFileSync(competingPath, "utf8"), "competing-owner\n", "atomic publication replaced a competing owner");

    const parentToken = processStartToken(process.pid);
    const parentPath = path.join(lockRoot, "parent.lock");
    fs.writeFileSync(parentPath, `${JSON.stringify({ parentPid: process.pid, parentStartToken: parentToken })}\n`);
    assert.equal(publisherLockParentState(parentPath), "alive");
    fs.writeFileSync(parentPath, `${JSON.stringify({ parentPid: process.pid, parentStartToken: "1" })}\n`);
    assert.equal(publisherLockParentState(parentPath), "retired");
    fs.writeFileSync(parentPath, "{partial");
    assert.equal(publisherLockParentState(parentPath), "unknown");
    fs.unlinkSync(parentPath);
    assert.equal(publisherLockParentState(parentPath), "absent");
  } finally { fs.rmSync(lockRoot, { recursive: true, force: true }); }

  let closed = false;
  let expression = null;
  const client = { close() { closed = true; } };
  const cdp = {
    async connectTarget(target, port) {
      assert.equal(target.url, TARGET_URL);
      assert.equal(port, 1234);
      return client;
    },
    async discoverTargets() {
      return [{ type: "page", url: "app://-/other.html" }, { type: "page", url: TARGET_URL }];
    },
    async evaluate(actualClient, source) {
      assert.equal(actualClient, client);
      expression = source;
      return true;
    },
  };
  assert.equal(await pulse(1234, cdp), true);
  assert.match(expression, /publishInventoryHeartbeat/u);
  assert.equal(closed, true);
  await assert.rejects(pulse(1234, {
    async discoverTargets() { return [{ type: "page", url: TARGET_URL }, { type: "webview", url: TARGET_URL }]; },
  }), /found 2/u);
  let pulseCount = 0;
  await run({ intervalMs: 1000, lockPath: null, parentPid: 42, parentStartToken: "original", port: 1234 }, {
    cdp: { async discoverTargets() { pulseCount += 1; return []; } },
    processMatches(pid, token) { assert.equal(pid, 42); assert.equal(token, "original"); return false; },
    async sleep() {},
  });
  assert.equal(pulseCount, 0, "a reused or replaced parent process must stop the heartbeat before another pulse");
  let transientChecks = 0;
  pulseCount = 0;
  await run({ intervalMs: 1000, lockPath: null, parentPid: 42, parentStartToken: "original", port: 1234 }, {
    cdp: { async discoverTargets() { pulseCount += 1; return []; } },
    processMatches() { transientChecks += 1; return transientChecks < 3 ? null : false; },
    async sleep() {},
  });
  assert.equal(pulseCount, 0, "heartbeat must pause while the exact parent identity is temporarily unverified");
  transientChecks = 0;
  pulseCount = 0;
  await run({ intervalMs: 1000, lockPath: null, parentPid: 42, parentStartToken: "original", port: 1234 }, {
    cdp: { async discoverTargets() { pulseCount += 1; return []; } },
    processMatches() { transientChecks += 1; return null; },
    async sleep() {},
  });
  assert.equal(transientChecks, 6);
  assert.equal(pulseCount, 0, "persistent identity lookup failure must never publish under an unverified process identity");

  for (const [platformName, publisher] of [["windows", windowsPublisher], ["macos", macPublisher]]) {
    let acquireAttempts = 0;
    let sleeps = 0;
    let releases = 0;
    const release = () => { releases += 1; };
    release.owns = () => true;
    await publisher.run({
      intervalMs: 1000,
      lockPath: `${platformName}-retiring.lock`,
      parentPid: 42,
      parentStartToken: "old-parent",
      port: 1234,
    }, {
      acquireLock() { acquireAttempts += 1; return acquireAttempts < 3 ? null : release; },
      cdp: {},
      now() { return acquireAttempts * 100; },
      processMatches() { return false; },
      publisherLockParentState() { return "retired"; },
      async sleep() { sleeps += 1; },
    });
    assert.equal(acquireAttempts, 3, `${platformName} successor did not retry while the old helper retired`);
    assert.equal(sleeps, 2, `${platformName} successor did not bound retries between ownership attempts`);
    assert.equal(releases, 1, `${platformName} successor did not retain exactly one publisher owner`);

    const retiringRoot = fs.mkdtempSync(path.join(os.tmpdir(), `publisher-${platformName}-retiring-`));
    const disappearingLock = path.join(retiringRoot, "owner.lock");
    fs.writeFileSync(disappearingLock, JSON.stringify({ parentPid: 42, parentStartToken: "old-parent" }));
    acquireAttempts = 0;
    sleeps = 0;
    const releasesBefore = releases;
    try {
      await publisher.run({ intervalMs: 1000, lockPath: disappearingLock, parentPid: 43, parentStartToken: "new-parent", port: 1234 }, {
        acquireLock() {
          acquireAttempts += 1;
          if (acquireAttempts === 1) { fs.unlinkSync(disappearingLock); return null; }
          return release;
        },
        cdp: {},
        processMatches() { return false; },
        async sleep() { sleeps += 1; },
      });
      assert.equal(acquireAttempts, 2, `${platformName} must retry exclusive acquisition when the old lock disappears before the parent-state read`);
      assert.equal(sleeps, 1);
      assert.equal(releases, releasesBefore + 1);
    } finally { fs.rmSync(retiringRoot, { recursive: true, force: true }); }

    for (const guardedState of ["alive", "unknown"]) {
      acquireAttempts = 0;
      sleeps = 0;
      await publisher.run({
        intervalMs: 1000,
        lockPath: `${platformName}-${guardedState}.lock`,
        parentPid: 42,
        parentStartToken: "current-parent",
        port: 1234,
      }, {
        acquireLock() { acquireAttempts += 1; return null; },
        cdp: {},
        publisherLockParentState() { return guardedState; },
        async sleep() { sleeps += 1; },
      });
      assert.equal(acquireAttempts, 1, `${platformName} retried over a ${guardedState} publisher owner`);
      assert.equal(sleeps, 0, `${platformName} waited to compete with a ${guardedState} publisher owner`);
    }
  }
  console.log("Publisher heartbeat self-test passed.");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
