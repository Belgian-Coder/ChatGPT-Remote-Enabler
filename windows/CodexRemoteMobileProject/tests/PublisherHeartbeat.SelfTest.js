"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const childProcess = require("node:child_process");
const { TARGET_URL, acquireLock, parseArgs, processMatches, processStartToken, pulse, run } = require("../publisher-heartbeat.js");

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
    assert.equal(acquireLock(lockPath, 100, "old-start", 1234), null, "same exact session must retain one helper");
    const releaseNew = acquireLock(lockPath, 100, "new-start", 1234);
    assert.equal(typeof releaseNew, "function", "a reused PID with a new start token must replace stale ownership");
    assert.equal(releaseOld.owns(), false, "replaced heartbeat must observe that it no longer owns the lock");
    releaseOld();
    assert.equal(fs.existsSync(lockPath), true, "the retiring helper must not remove its successor lock");
    releaseNew();
    assert.equal(fs.existsSync(lockPath), false);
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
  console.log("Publisher heartbeat self-test passed.");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
