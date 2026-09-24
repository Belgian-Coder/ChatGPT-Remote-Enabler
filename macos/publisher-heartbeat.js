// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Clean-room contributors

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const childProcess = require("node:child_process");

const TARGET_URL = "app://-/index.html";
const UPDATE_HANDOFF_PROTOCOL_VERSION = 2;
const PUBLISHER_LOCK_PROTOCOL_VERSION = 2;
const LOCK_RETIRE_WAIT_MS = 30_000;
const LOCK_RETRY_INTERVAL_MS = 250;

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) throw new Error("Invalid publisher heartbeat arguments");
    values[key.slice(2)] = value;
  }
  const port = Number(values.port);
  const parentPid = Number(values["parent-pid"]);
  const parentStartToken = String(values["parent-start-token"] ?? "");
  const intervalMs = values["interval-ms"] === undefined ? 10_000 : Number(values["interval-ms"]);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid renderer port");
  if (!Number.isInteger(parentPid) || parentPid < 1) throw new Error("Invalid parent process id");
  if (!parentStartToken || parentStartToken.length > 200 || /[\r\n]/u.test(parentStartToken)) throw new Error("Invalid parent process start token");
  if (!Number.isInteger(intervalMs) || intervalMs < 1_000 || intervalMs > 60_000) throw new Error("Invalid heartbeat interval");
  const lockPath = values["lock-path"] ? path.resolve(values["lock-path"]) : null;
  return { intervalMs, lockPath, parentPid, parentStartToken, port };
}

function processExists(pid) {
  try { process.kill(pid, 0); return true; }
  catch (error) { return error?.code === "EPERM"; }
}

function processStartToken(pid) {
  if (!Number.isInteger(pid) || pid < 1) return null;
  try {
    if (process.platform === "win32") {
      const output = childProcess.execFileSync("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", `(Get-Process -Id ${pid} -ErrorAction Stop).StartTime.ToUniversalTime().ToFileTimeUtc()`], {
        encoding: "utf8", timeout: 5000, windowsHide: true, stdio: ["ignore", "pipe", "ignore"],
      });
      const token = output.trim();
      return /^\d+$/u.test(token) ? token : null;
    }
    if (process.platform === "darwin") {
      const output = childProcess.execFileSync("/bin/ps", ["-p", String(pid), "-o", "lstart="], {
        encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
      });
      const token = output.trim().replace(/\s+/gu, " ");
      return token || null;
    }
  } catch {}
  return null;
}

function processMatches(pid, expectedStartToken) {
  if (!processExists(pid)) return false;
  const actualStartToken = processStartToken(pid);
  return actualStartToken === null ? null : actualStartToken === expectedStartToken;
}

function publisherOwnerState(owner, dependencies = {}) {
  if (!Number.isInteger(owner?.pid) || owner.pid < 1) return "unknown";
  const validStartToken = typeof owner.publisherStartToken === "string"
    && owner.publisherStartToken.length > 0 && owner.publisherStartToken.length <= 200
    && !/[\r\n]/u.test(owner.publisherStartToken)
    && (process.platform !== "win32" || /^\d+$/u.test(owner.publisherStartToken));
  if (owner.protocolVersion === PUBLISHER_LOCK_PROTOCOL_VERSION
      && validStartToken) {
    const matches = dependencies.processMatches ?? processMatches;
    const result = matches(owner.pid, owner.publisherStartToken);
    return result === true ? "alive" : result === false ? "retired" : "unknown";
  }
  const exists = dependencies.processExists ?? processExists;
  return exists(owner.pid) ? "alive" : "retired";
}

function publisherLockParentState(lockPath, dependencies = {}) {
  let owner;
  try { owner = JSON.parse(fs.readFileSync(lockPath, "utf8")); }
  catch (error) { return error?.code === "ENOENT" ? "absent" : "unknown"; }
  if (!Number.isInteger(owner?.parentPid) || owner.parentPid < 1
      || typeof owner.parentStartToken !== "string" || owner.parentStartToken.length < 1
      || owner.parentStartToken.length > 200 || /[\r\n]/u.test(owner.parentStartToken)) return "unknown";
  const matches = dependencies.processMatches ?? processMatches;
  const result = matches(owner.parentPid, owner.parentStartToken);
  return result === true ? "alive" : result === false ? "retired" : "unknown";
}

function publishLockAtomically(lockPath, contents, dependencies = {}) {
  const io = dependencies.fs ?? fs;
  const temporaryPath = path.join(
    path.dirname(lockPath),
    `.${path.basename(lockPath)}.create-${process.pid}-${crypto.randomBytes(12).toString("hex")}.tmp`,
  );
  let handle = null;
  try {
    handle = io.openSync(temporaryPath, "wx", 0o600);
    io.writeFileSync(handle, contents);
    io.fsyncSync(handle);
    io.closeSync(handle);
    handle = null;
    dependencies.beforeLink?.(temporaryPath, lockPath);
    io.linkSync(temporaryPath, lockPath);
  } finally {
    if (handle !== null) {
      try { io.closeSync(handle); } catch {}
    }
    try { io.rmSync(temporaryPath, { force: true }); } catch {}
  }
}

function resolveCdp() {
  const candidates = [
    path.join(__dirname, "..", "CodexRemoteSimple", "runtime", "lib", "cdp.js"),
    path.join(__dirname, "cdp.js"),
  ];
  const selected = candidates.find((candidate) => fs.existsSync(candidate));
  if (!selected) throw new Error("Publisher heartbeat CDP dependency is missing");
  return require(selected);
}

async function pulse(port, cdp = resolveCdp()) {
  const targets = (await cdp.discoverTargets(port, 5_000))
    .filter((target) => (target?.type === "page" || target?.type === "webview") && target.url === TARGET_URL);
  if (targets.length !== 1) throw new Error(`Expected one exact publisher target; found ${targets.length}`);
  const client = await cdp.connectTarget(targets[0], port, 5_000);
  try {
    return await cdp.evaluate(
      client,
      "globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.publishInventoryHeartbeat?.() === true",
      5_000,
    ) === true;
  } finally {
    client.close();
  }
}

function acquireLock(lockPath, parentPid, parentStartToken, port) {
  if (!lockPath) {
    const release = () => {};
    release.owns = () => true;
    return release;
  }
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const token = crypto.randomBytes(24).toString("hex");
      const publisherStartToken = processStartToken(process.pid);
      if (publisherStartToken === null) throw new Error("Publisher process identity is unavailable");
      const contents = `${JSON.stringify({
        executablePath: path.resolve(process.execPath),
        parentPid,
        parentStartToken,
        pid: process.pid,
        port,
        protocolVersion: PUBLISHER_LOCK_PROTOCOL_VERSION,
        publisherStartToken,
        scriptPath: path.resolve(__filename),
        state: "active",
        token,
      })}\n`;
      publishLockAtomically(lockPath, contents);
      const release = () => {
        try {
          const current = JSON.parse(fs.readFileSync(lockPath, "utf8"));
          if (current?.token === token) fs.rmSync(lockPath, { force: true });
        } catch {}
      };
      release.owns = () => {
        try { return JSON.parse(fs.readFileSync(lockPath, "utf8"))?.token === token; }
        catch { return false; }
      };
      return release;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      let owner = null;
      try { owner = JSON.parse(fs.readFileSync(lockPath, "utf8")); }
      catch { return null; }
      if (owner?.state === "handoff") return null;
      if (publisherOwnerState(owner) !== "retired") return null;
      try { fs.rmSync(lockPath, { force: true }); } catch {}
    }
  }
  return null;
}

async function run(options, dependencies = {}) {
  const cdp = dependencies.cdp ?? resolveCdp();
  const matches = dependencies.processMatches ?? processMatches;
  const sleep = dependencies.sleep ?? ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)));
  const acquire = dependencies.acquireLock ?? acquireLock;
  const parentState = dependencies.publisherLockParentState ?? publisherLockParentState;
  const now = dependencies.now ?? Date.now;
  let releaseLock = acquire(options.lockPath, options.parentPid, options.parentStartToken, options.port);
  if (releaseLock === null && options.lockPath) {
    const deadline = now() + LOCK_RETIRE_WAIT_MS;
    while (releaseLock === null) {
      if (!["retired", "absent"].includes(parentState(options.lockPath)) || now() >= deadline) return;
      await sleep(Math.min(LOCK_RETRY_INTERVAL_MS, Math.max(1, deadline - now())));
      releaseLock = acquire(options.lockPath, options.parentPid, options.parentStartToken, options.port);
    }
  }
  if (releaseLock === null) return;
  let stopping = false;
  const stop = () => { stopping = true; };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    let consecutiveIdentityFailures = 0;
    while (!stopping && releaseLock.owns()) {
      const identityMatch = matches(options.parentPid, options.parentStartToken);
      if (identityMatch === false) break;
      if (identityMatch === null) {
        consecutiveIdentityFailures += 1;
        if (consecutiveIdentityFailures >= 6) break;
        await sleep(options.intervalMs);
        continue;
      } else {
        consecutiveIdentityFailures = 0;
      }
      try { await pulse(options.port, cdp); } catch {}
      await sleep(options.intervalMs);
    }
  } finally {
    process.removeListener("SIGINT", stop);
    process.removeListener("SIGTERM", stop);
    releaseLock();
  }
}

if (require.main === module) {
  run(parseArgs(process.argv.slice(2))).catch(() => { process.exitCode = 1; });
}

module.exports = {
  PUBLISHER_LOCK_PROTOCOL_VERSION,
  LOCK_RETIRE_WAIT_MS,
  TARGET_URL,
  UPDATE_HANDOFF_PROTOCOL_VERSION,
  acquireLock,
  parseArgs,
  processExists,
  processMatches,
  processStartToken,
  publishLockAtomically,
  publisherLockParentState,
  publisherOwnerState,
  pulse,
  run,
};
