// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Clean-room contributors

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

function atomicResult(file, value) {
  const temporary = `${file}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value)}\n`, { encoding: "utf8", mode: 0o600 });
    for (let attempt = 0; ; attempt += 1) {
      try { fs.renameSync(temporary, file); break; }
      catch (error) {
        if (!["EPERM", "EACCES", "EBUSY"].includes(error?.code) || attempt >= 9) throw error;
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20 * (attempt + 1));
      }
    }
  } finally {
    try { fs.rmSync(temporary, { force: true }); } catch {}
  }
}

function processAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (error) { return error?.code === "EPERM"; }
}

function parseLastJson(text) {
  const lines = String(text || "").split(/\r?\n/u).map((line) => line.trim()).filter(Boolean);
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    try { return JSON.parse(lines[index]); } catch {}
  }
  return null;
}

function windowsPowerShellModulePath(env) {
  return [
    env.USERPROFILE && path.join(env.USERPROFILE, "Documents", "WindowsPowerShell", "Modules"),
    env.ProgramFiles && path.join(env.ProgramFiles, "WindowsPowerShell", "Modules"),
    env.SystemRoot && path.join(env.SystemRoot, "System32", "WindowsPowerShell", "v1.0", "Modules"),
  ].filter(Boolean).join(";");
}

function exactChildConfig(config, configPath) {
  if (!config || !["win32", "darwin"].includes(config.platform) ||
      typeof config.attemptId !== "string" || !/^[a-f0-9]{32}$/u.test(config.attemptId) ||
      !Number.isSafeInteger(config.previousPid) || config.previousPid <= 0 || !Number.isSafeInteger(config.appPid) || config.appPid <= 0) {
    throw new Error("The coordinator handoff identity is invalid.");
  }
  for (const key of ["installRoot", "stateRoot", "previousSessionDirectory", "configPath", "platformHelperPath", "lockPath", "resultPath", "releasePath", "nodePath", "launcherPath"]) {
    if (typeof config[key] !== "string" || !path.isAbsolute(config[key])) throw new Error(`The coordinator handoff ${key} is invalid.`);
    config[key] = path.resolve(config[key]);
  }
  const sessionDirectory = path.dirname(configPath);
  if (path.basename(configPath) !== `coordinator-handoff-${config.attemptId}.json` ||
      path.dirname(config.resultPath) !== sessionDirectory || path.basename(config.resultPath) !== `coordinator-handoff-result-${config.attemptId}.json`) {
    throw new Error("The coordinator handoff result path is outside its session.");
  }
  if (path.dirname(config.releasePath) !== sessionDirectory || path.basename(config.releasePath) !== `coordinator-handoff-release-${config.attemptId}.json` ||
      path.resolve(config.configPath) !== path.join(sessionDirectory, "session.json")) {
    throw new Error("The coordinator handoff release or source configuration path is outside its session.");
  }
  if (path.resolve(config.previousSessionDirectory) !== sessionDirectory ||
      path.dirname(sessionDirectory) !== path.join(config.stateRoot, "sessions") ||
      typeof config.expectedVersion !== "string" || !/^v\d+\.\d+\.\d+$/u.test(config.expectedVersion)) {
    throw new Error("The coordinator handoff session or version binding is invalid.");
  }
  const expectedLauncher = config.platform === "win32"
    ? path.join(config.installRoot, "CodexRemoteMobileProject", "UpdateSessionLauncher.ps1")
    : path.join(config.installRoot, "MobileProjectView-macOS-arm64.sh");
  const compare = (value) => config.platform === "win32" ? value.toLowerCase() : value;
  if (compare(config.launcherPath) !== compare(path.resolve(expectedLauncher)) ||
      !fs.existsSync(config.launcherPath) || fs.lstatSync(config.launcherPath).isSymbolicLink()) {
    throw new Error("The installed coordinator launcher is unavailable.");
  }
  const previousConfig = JSON.parse(fs.readFileSync(config.configPath, "utf8"));
  if (compare(path.resolve(previousConfig.platformHelperPath || "")) !== compare(config.platformHelperPath) ||
      compare(path.resolve(previousConfig.installRoot || "")) !== compare(config.installRoot) ||
      previousConfig.app?.pid !== config.appPid || !sameAppIdentity(previousConfig.app, config.app, config.platform)) {
    throw new Error("The coordinator handoff application or platform-helper binding changed.");
  }
  return config;
}

function exactAppAlive(config) {
  let child;
  if (config.platform === "win32") {
    const shell = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
    child = spawnSync(shell, ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
      config.platformHelperPath, "-Action", "Probe", "-ConfigPath", config.configPath, "-NodePath", config.nodePath],
    { cwd: config.previousSessionDirectory, encoding: "utf8", timeout: 15_000, windowsHide: true });
  } else {
    child = spawnSync("/bin/zsh", [config.platformHelperPath, "Probe", config.configPath],
      { cwd: config.previousSessionDirectory, encoding: "utf8", timeout: 15_000 });
  }
  return child.status === 0 && !child.error && parseLastJson(child.stdout)?.running === true;
}

function sameAppIdentity(left, right, platform) {
  if (!left || !right || left.pid !== right.pid || left.executablePath !== right.executablePath) return false;
  return platform === "win32"
    ? left.startTimeFileTimeUtc === right.startTimeFileTimeUtc
    : left.startToken === right.startToken && left.appPath === right.appPath && left.bundleId === right.bundleId;
}

function queryCoordinatorProcessIdentity(pid, platform, expectedExecutablePath) {
  if (!Number.isSafeInteger(pid) || pid <= 0 || typeof expectedExecutablePath !== "string" || !path.isAbsolute(expectedExecutablePath)) return null;
  try {
    if (platform === "win32") {
      const shell = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
      const script = `$p=Get-Process -Id ${pid} -ErrorAction Stop; [pscustomobject]@{pid=$p.Id;startToken=$p.StartTime.ToUniversalTime().ToFileTimeUtc().ToString();executablePath=$p.Path}|ConvertTo-Json -Compress`;
      const child = spawnSync(shell, ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
        { encoding: "utf8", timeout: 3_000, windowsHide: true });
      const value = child.status === 0 && !child.error ? parseLastJson(child.stdout) : null;
      return value && value.pid === pid && /^\d{16,20}$/u.test(value.startToken) && path.isAbsolute(value.executablePath) ? value : null;
    }
    if (platform === "darwin") {
      const child = spawnSync("/bin/ps", ["-p", String(pid), "-o", "lstart="],
        { encoding: "utf8", timeout: 5_000, env: { ...process.env, LC_ALL: "C", LANG: "C" } });
      const startToken = child.status === 0 && !child.error ? String(child.stdout || "").trim().replace(/\s+/gu, " ") : "";
      return startToken ? { pid, startToken, executablePath: expectedExecutablePath } : null;
    }
  } catch {}
  return null;
}

function sameCoordinatorProcessIdentity(left, right, platform) {
  if (!left || !right || left.pid !== right.pid || left.startToken !== right.startToken) return false;
  return platform === "win32"
    ? String(left.executablePath).toLowerCase() === String(right.executablePath).toLowerCase()
    : true;
}

async function main(argv = process.argv.slice(2)) {
  const configPath = argv[0];
  if (!configPath || !path.isAbsolute(configPath)) throw new Error("Usage: coordinator-handoff.js <absolute-config-path>");
  const resolvedConfig = path.resolve(configPath);
  const config = exactChildConfig(JSON.parse(fs.readFileSync(resolvedConfig, "utf8")), resolvedConfig);
  if (!exactAppAlive(config)) {
    atomicResult(config.resultPath, { attemptId: config.attemptId, started: false, reason: "exact-chatgpt-identity-changed" });
    throw new Error("The exact ChatGPT process changed before coordinator handoff.");
  }
  atomicResult(config.resultPath, { attemptId: config.attemptId, armed: true, started: false });
  const releaseDeadline = Date.now() + 10_000;
  while ((!fs.existsSync(config.releasePath) || fs.existsSync(config.lockPath)) && Date.now() < releaseDeadline) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  let release;
  try { release = JSON.parse(fs.readFileSync(config.releasePath, "utf8")); } catch {}
  if (release?.release !== true || release?.attemptId !== config.attemptId || release?.previousPid !== config.previousPid || fs.existsSync(config.lockPath)) {
    atomicResult(config.resultPath, { attemptId: config.attemptId, started: false, reason: "previous-coordinator-did-not-transfer-lock" });
    throw new Error("The previous coordinator did not transfer its session lock.");
  }
  let candidatePid = null;
  let candidateIdentity = null;
  const captureExactLockOwner = () => {
    try {
      const lockOwner = JSON.parse(fs.readFileSync(config.lockPath, "utf8"));
      if (!Number.isSafeInteger(lockOwner?.pid) || lockOwner.pid <= 0 || lockOwner.pid === config.previousPid) return false;
      candidatePid = lockOwner.pid;
      candidateIdentity = lockOwner;
      const live = queryCoordinatorProcessIdentity(lockOwner.pid, config.platform, lockOwner?.executablePath);
      if (!sameCoordinatorProcessIdentity(lockOwner, live, config.platform)) return false;
      return true;
    } catch { return false; }
  };
  const exactCandidateAlive = () => sameCoordinatorProcessIdentity(candidateIdentity,
    queryCoordinatorProcessIdentity(candidatePid, config.platform, candidateIdentity?.executablePath), config.platform);
  const stopExactCandidate = async () => {
    if ((!Number.isSafeInteger(candidatePid) || candidatePid <= 0 || candidatePid === config.previousPid) && !captureExactLockOwner()) return true;
    if (!exactCandidateAlive()) return !processAlive(candidatePid);
    try { process.kill(candidatePid); } catch {}
    const stopDeadline = Date.now() + 8_000;
    let forced = false;
    while (Date.now() < stopDeadline) {
      if (!exactCandidateAlive()) return true;
      if (!forced && Date.now() >= stopDeadline - 3_500) {
        if (exactCandidateAlive()) try { process.kill(candidatePid, "SIGKILL"); } catch {}
        forced = true;
      }
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    return !exactCandidateAlive();
  };
  const sessionsRoot = path.join(config.stateRoot, "sessions");
  let command;
  let args;
  const env = { ...process.env };
  if (config.platform === "win32") {
    env.PSModulePath = windowsPowerShellModulePath(env);
    command = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
    args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File",
      config.launcherPath, "-InstallRoot", config.installRoot, "-EntryPointRelative", config.entryPointRelative,
      "-NodePath", config.nodePath, "-SkipInitialCheck"];
    if (config.useProxy === true) args.push("-UseProxy");
    if (config.replaceRunningApp === true) args.push("-ReplaceRunningApp");
  } else {
    command = "/bin/zsh";
    args = [config.launcherPath, "handoff-update-session"];
    if (config.useProxy === true) args.push("--proxy");
    env.CODEX_REMOTE_DEBUG_PORT = String(config.rendererPort);
    env.CODEX_REMOTE_SKIP_UPDATE_CHECK_ONCE = "1";
    for (const [name, value] of Object.entries(config.environment ?? {})) {
      if (["CODEX_APP_NAME", "CODEX_REMOTE_PEER_NAME", "CODEX_STARTUP_REQUIRED_PATH", "CODEX_REMOTE_USE_PROXY"].includes(name) && typeof value === "string") env[name] = value;
    }
  }
  let readinessProven = false;
  try {
  if (exactAppAlive(config)) {
    const before = new Set(fs.existsSync(sessionsRoot) ? fs.readdirSync(sessionsRoot) : []);
    const child = spawnSync(command, args, { cwd: config.installRoot, env, encoding: "utf8", timeout: config.platform === "win32" ? 90_000 : 20_000, windowsHide: true });
    const activationDeadline = Date.now() + (config.platform === "win32" ? 15_000 : 45_000);
    let started = child.status === 0 && !child.error;
    let readySession = null;
    do {
      for (const name of fs.existsSync(sessionsRoot) ? fs.readdirSync(sessionsRoot) : []) {
        if (before.has(name) || !/^[a-f0-9-]{32,36}$/iu.test(name)) continue;
      const directory = path.join(sessionsRoot, name);
      try {
        const session = JSON.parse(fs.readFileSync(path.join(directory, "session.json"), "utf8"));
        const state = JSON.parse(fs.readFileSync(path.join(directory, "coordinator-state.json"), "utf8"));
        if (path.resolve(session.installRoot) === config.installRoot && session.rendererPort === config.rendererPort &&
            sameAppIdentity(session.app, config.app, config.platform) && Number.isSafeInteger(state.coordinatorPid) &&
            state.coordinatorPid !== config.previousPid) {
          candidatePid = state.coordinatorPid;
          candidateIdentity = state.coordinatorIdentity ?? null;
          if (state.phase === "active" && Date.now() - state.heartbeatAtUnixMs <= 10_000 &&
              sameCoordinatorProcessIdentity(candidateIdentity,
                queryCoordinatorProcessIdentity(candidatePid, config.platform, candidateIdentity?.executablePath), config.platform)) {
            readySession = directory;
            break;
          }
        }
      } catch {}
      }
      if (!readySession && Date.now() < activationDeadline) await new Promise((resolve) => setTimeout(resolve, 100));
      else break;
    } while (!readySession && Date.now() < activationDeadline);
    started = readySession !== null && exactAppAlive(config) &&
      fs.readFileSync(path.join(config.installRoot, "VERSION"), "utf8").trim() === config.expectedVersion;
    readinessProven = started;
    if (!started) captureExactLockOwner();
    const candidateStopped = started ? false : await stopExactCandidate();
    atomicResult(config.resultPath, { attemptId: config.attemptId, started, readySession, exitCode: child.status,
      reason: started ? null : "replacement-coordinator-not-ready",
      candidatePid, candidateStopped,
      error: child.error ? String(child.error.message || child.error).slice(0, 240) : null });
    if (started) return { started: true };
  }
  else {
    atomicResult(config.resultPath, { attemptId: config.attemptId, started: false, reason: "exact-chatgpt-identity-changed-after-release" });
  }
  } catch (error) {
    if (!readinessProven) captureExactLockOwner();
    const candidateStopped = readinessProven ? false : await stopExactCandidate();
    let current = null;
    try { current = JSON.parse(fs.readFileSync(config.resultPath, "utf8")); } catch {}
    if (current?.attemptId !== config.attemptId || current?.armed === true) {
      atomicResult(config.resultPath, { attemptId: config.attemptId, started: false, reason: "handoff-helper-error",
        candidatePid, candidateStopped,
        error: String(error?.message || error).replace(/[\r\n\0]+/gu, " ").slice(0, 240) });
    }
    throw error;
  }
  throw new Error("The exact ChatGPT process changed or the updated coordinator did not become ready.");
}

module.exports = { atomicResult, exactAppAlive, exactChildConfig, main, parseLastJson, processAlive, queryCoordinatorProcessIdentity,
  sameAppIdentity, sameCoordinatorProcessIdentity, windowsPowerShellModulePath };

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`${String(error?.message || error).replace(/[\r\n\0]+/gu, " ").slice(0, 320)}\n`);
    process.exitCode = 1;
  });
}
