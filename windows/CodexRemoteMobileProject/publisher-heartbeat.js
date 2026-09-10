// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Clean-room contributors

"use strict";

const fs = require("node:fs");
const path = require("node:path");

const TARGET_URL = "app://-/index.html";

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
  const intervalMs = values["interval-ms"] === undefined ? 10_000 : Number(values["interval-ms"]);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid renderer port");
  if (!Number.isInteger(parentPid) || parentPid < 1) throw new Error("Invalid parent process id");
  if (!Number.isInteger(intervalMs) || intervalMs < 1_000 || intervalMs > 60_000) throw new Error("Invalid heartbeat interval");
  const lockPath = values["lock-path"] ? path.resolve(values["lock-path"]) : null;
  return { intervalMs, lockPath, parentPid, port };
}

function processExists(pid) {
  try { process.kill(pid, 0); return true; }
  catch (error) { return error?.code === "EPERM"; }
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

function acquireLock(lockPath, parentPid, port) {
  if (!lockPath) return () => {};
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const handle = fs.openSync(lockPath, "wx", 0o600);
      fs.writeFileSync(handle, `${JSON.stringify({ parentPid, pid: process.pid, port })}\n`);
      fs.closeSync(handle);
      return () => { try { fs.rmSync(lockPath, { force: true }); } catch {} };
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      let owner = null;
      try { owner = JSON.parse(fs.readFileSync(lockPath, "utf8")); } catch {}
      if (Number.isInteger(owner?.pid) && processExists(owner.pid)) return null;
      try { fs.rmSync(lockPath, { force: true }); } catch {}
    }
  }
  return null;
}

async function run(options, dependencies = {}) {
  const cdp = dependencies.cdp ?? resolveCdp();
  const exists = dependencies.processExists ?? processExists;
  const releaseLock = acquireLock(options.lockPath, options.parentPid, options.port);
  if (releaseLock === null) return;
  let stopping = false;
  const stop = () => { stopping = true; };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    while (!stopping && exists(options.parentPid)) {
      try { await pulse(options.port, cdp); } catch {}
      await new Promise((resolve) => setTimeout(resolve, options.intervalMs));
    }
  } finally {
    releaseLock();
  }
}

if (require.main === module) {
  run(parseArgs(process.argv.slice(2))).catch(() => { process.exitCode = 1; });
}

module.exports = { TARGET_URL, parseArgs, processExists, pulse, run };
