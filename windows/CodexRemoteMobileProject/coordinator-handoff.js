// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Clean-room contributors

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

function atomicResult(file, value) {
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(value)}\n`, { encoding: "utf8", mode: 0o600 });
  fs.renameSync(temporary, file);
}

function processAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (error) { return error?.code === "EPERM"; }
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
      !Number.isSafeInteger(config.previousPid) || config.previousPid <= 0 || !Number.isSafeInteger(config.appPid) || config.appPid <= 0) {
    throw new Error("The coordinator handoff identity is invalid.");
  }
  for (const key of ["installRoot", "stateRoot", "previousSessionDirectory", "lockPath", "resultPath", "nodePath", "launcherPath"]) {
    if (typeof config[key] !== "string" || !path.isAbsolute(config[key])) throw new Error(`The coordinator handoff ${key} is invalid.`);
    config[key] = path.resolve(config[key]);
  }
  const sessionDirectory = path.dirname(configPath);
  if (path.dirname(config.resultPath) !== sessionDirectory || path.basename(config.resultPath) !== "coordinator-handoff-result.json") {
    throw new Error("The coordinator handoff result path is outside its session.");
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
  return config;
}

async function main(argv = process.argv.slice(2)) {
  const configPath = argv[0];
  if (!configPath || !path.isAbsolute(configPath)) throw new Error("Usage: coordinator-handoff.js <absolute-config-path>");
  const resolvedConfig = path.resolve(configPath);
  const config = exactChildConfig(JSON.parse(fs.readFileSync(resolvedConfig, "utf8")), resolvedConfig);
  const deadline = Date.now() + 30_000;
  while ((processAlive(config.previousPid) || fs.existsSync(config.lockPath)) && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (processAlive(config.previousPid) || fs.existsSync(config.lockPath)) {
    atomicResult(config.resultPath, { started: false, reason: "previous-coordinator-did-not-release" });
    throw new Error("The previous coordinator did not release its session lock.");
  }
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
  while (processAlive(config.appPid)) {
    const before = new Set(fs.existsSync(sessionsRoot) ? fs.readdirSync(sessionsRoot) : []);
    const child = spawnSync(command, args, { cwd: config.installRoot, env, encoding: "utf8", timeout: 45_000, windowsHide: true });
    let started = child.status === 0 && !child.error;
    let readySession = null;
    const readyDeadline = Date.now() + 35_000;
    while (started && !readySession && Date.now() < readyDeadline) {
      for (const name of fs.existsSync(sessionsRoot) ? fs.readdirSync(sessionsRoot) : []) {
        if (before.has(name) || !/^[a-f0-9-]{32,36}$/iu.test(name)) continue;
      const directory = path.join(sessionsRoot, name);
      try {
        const session = JSON.parse(fs.readFileSync(path.join(directory, "session.json"), "utf8"));
        const state = JSON.parse(fs.readFileSync(path.join(directory, "coordinator-state.json"), "utf8"));
        if (path.resolve(session.installRoot) === config.installRoot && session.rendererPort === config.rendererPort &&
            state.phase === "active" && Date.now() - state.heartbeatAtUnixMs <= 10_000 && processAlive(state.coordinatorPid)) {
          readySession = directory;
          break;
        }
      } catch {}
      }
      if (!readySession) await new Promise((resolve) => setTimeout(resolve, 100));
    }
    started = started && readySession !== null && fs.readFileSync(path.join(config.installRoot, "VERSION"), "utf8").trim() === config.expectedVersion;
    atomicResult(config.resultPath, { started, readySession, exitCode: child.status, error: child.error ? String(child.error.message || child.error).slice(0, 240) : null });
    if (started) return { started: true };
    await new Promise((resolve) => setTimeout(resolve, 5000));
  }
  throw new Error("The ChatGPT process exited before the updated coordinator became ready.");
}

module.exports = { exactChildConfig, main, processAlive, windowsPowerShellModulePath };

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`${String(error?.message || error).replace(/[\r\n\0]+/gu, " ").slice(0, 320)}\n`);
    process.exitCode = 1;
  });
}
