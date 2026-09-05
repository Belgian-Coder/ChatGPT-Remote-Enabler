// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Clean-room contributors

"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { BINDING_NAME, CdpTransport, TARGET_URL, bootstrapSource } = require("./update-session-cdp.js");

const UPDATE_INTERVAL_MS = 30 * 60 * 1000;
const STATUS_STATES = new Set([
  "checking", "current", "available", "queued", "preparing", "closing",
  "updating", "restarting", "error", "unavailable",
]);
const REQUEST_ACTIONS = new Set(["check", "queue", "cancel"]);

function cleanMessage(value, fallback = null) {
  if (typeof value !== "string") return fallback;
  const cleaned = value.replace(/[\r\n\0]+/gu, " ").trim().slice(0, 320);
  return cleaned || fallback;
}

function canonicalStatus(value) {
  const state = STATUS_STATES.has(value?.state) ? value.state : "unavailable";
  return Object.freeze({
    state,
    version: typeof value?.version === "string" && value.version ? value.version : null,
    message: cleanMessage(value?.message),
    canCancel: value?.canCancel === true,
    canQueue: value?.canQueue === true,
  });
}

function validVersion(value) {
  return typeof value === "string" && /^v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/u.test(value);
}

function validSha256(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/iu.test(value);
}

function parseLastJson(stdout) {
  const complete = String(stdout ?? "").trim();
  if (complete) {
    try {
      const value = JSON.parse(complete);
      if (value && typeof value === "object") return value;
    } catch {
      // Fall back to a framed final line when progress preceded the result.
    }
  }
  const lines = String(stdout ?? "").split(/\r?\n/u).map((line) => line.trim()).filter(Boolean);
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    try {
      const value = JSON.parse(lines[index]);
      if (value && typeof value === "object") return value;
    } catch {
      // Updaters may emit progress before their final JSON object.
    }
  }
  throw new Error("The updater did not return a JSON result.");
}

function sleep(milliseconds) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, milliseconds);
    timer.unref?.();
  });
}

async function terminateOwnedProcessTree(child) {
  if (!Number.isInteger(child?.pid) || child.pid <= 0) return false;
  if (process.platform === "win32") {
    const systemRoot = process.env.SystemRoot || process.env.WINDIR;
    if (typeof systemRoot !== "string" || !path.isAbsolute(systemRoot)) return false;
    const taskkill = path.join(systemRoot, "System32", "taskkill.exe");
    return new Promise((resolve) => {
      let settled = false;
      const finish = (value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(value);
      };
      const timer = setTimeout(() => finish(false), 10_000);
      let killer;
      try {
        killer = spawn(taskkill, ["/PID", String(child.pid), "/T", "/F"], {
          stdio: "ignore", windowsHide: true,
        });
      } catch {
        finish(false);
        return;
      }
      killer.once("error", () => finish(false));
      killer.once("close", (code) => finish(code === 0));
    });
  }

  const groupExists = () => {
    try { process.kill(-child.pid, 0); return true; }
    catch (error) { return error?.code !== "ESRCH"; }
  };
  try { process.kill(-child.pid, "SIGTERM"); }
  catch (error) { if (error?.code === "ESRCH") return true; else return false; }
  await new Promise((resolve) => setTimeout(resolve, 500));
  if (groupExists()) {
    try { process.kill(-child.pid, "SIGKILL"); }
    catch (error) { if (error?.code !== "ESRCH") return false; }
  }
  const deadline = Date.now() + 5_000;
  while (groupExists() && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return !groupExists();
}

function runCommand(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      detached: process.platform !== "win32",
      env: options.env ?? process.env,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    const stdout = [];
    const stderr = [];
    let outputLength = 0;
    let settled = false;
    let timedOut = false;
    const timeoutMs = options.timeoutMs ?? 180_000;
    const timer = setTimeout(() => {
      timedOut = true;
      void terminateOwnedProcessTree(child).then((terminated) => {
        if (settled) return;
        settled = true;
        const error = new Error(terminated
          ? `Command timed out after ${timeoutMs} milliseconds.`
          : `Command timed out after ${timeoutMs} milliseconds, and its owned process tree could not be proven stopped.`);
        error.commandTreeTerminationUnverified = !terminated;
        reject(error);
      }, () => {
        if (settled) return;
        settled = true;
        const error = new Error(`Command timed out after ${timeoutMs} milliseconds, and its owned process tree could not be proven stopped.`);
        error.commandTreeTerminationUnverified = true;
        reject(error);
      });
    }, timeoutMs);
    timer.unref?.();
    const append = (destination, chunk) => {
      outputLength += chunk.length;
      if (outputLength <= 8 * 1024 * 1024) destination.push(chunk);
    };
    child.stdout.on("data", (chunk) => append(stdout, chunk));
    child.stderr.on("data", (chunk) => append(stderr, chunk));
    child.on("error", (error) => {
      if (timedOut || settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      if (timedOut || settled) return;
      settled = true;
      clearTimeout(timer);
      const out = Buffer.concat(stdout).toString("utf8");
      const err = Buffer.concat(stderr).toString("utf8");
      if (code === 0) {
        resolve({ stdout: out, stderr: err });
        return;
      }
      const message = cleanMessage(err || out, `Command failed with exit code ${code}.`);
      const error = new Error(message);
      error.exitCode = code;
      error.stdout = out;
      error.stderr = err;
      reject(error);
    });
  });
}

function ensureConfig(config) {
  if (!config || config.schemaVersion !== 1 || !["win32", "darwin"].includes(config.platform)) {
    throw new Error("The update-session configuration is invalid.");
  }
  for (const name of ["installRoot", "platformHelperPath", "sessionDirectory", "stateRoot", "updaterPath"]) {
    if (typeof config[name] !== "string" || !path.isAbsolute(config[name])) {
      throw new Error(`The update-session configuration has no absolute ${name}.`);
    }
  }
  const normalize = (value) => config.platform === "win32" ? value.toLowerCase() : value;
  const stateRoot = path.resolve(config.stateRoot);
  const sessionRoot = path.join(stateRoot, "sessions");
  const sessionDirectory = path.resolve(config.sessionDirectory);
  if (!normalize(sessionDirectory).startsWith(normalize(sessionRoot + path.sep)) || sessionDirectory === sessionRoot) {
    throw new Error("The update-session directory is outside the per-user session root.");
  }
  const updaterPath = path.resolve(config.updaterPath);
  const platformHelperPath = path.resolve(config.platformHelperPath);
  const bundleRoot = path.dirname(updaterPath);
  const bundlesRoot = path.join(stateRoot, "bundles") + path.sep;
  if (!normalize(bundleRoot).startsWith(normalize(bundlesRoot)) ||
      normalize(path.dirname(platformHelperPath)) !== normalize(bundleRoot) ||
      !/^[0-9a-f]{64}$/u.test(path.basename(bundleRoot))) {
    throw new Error("The update-session dependencies are outside an immutable bundle snapshot.");
  }
  if (!Number.isInteger(config.rendererPort) || config.rendererPort < 1024 || config.rendererPort > 65535) {
    throw new Error("The update-session renderer port is invalid.");
  }
  if (!Number.isInteger(config.app?.pid) || config.app.pid <= 0 ||
      typeof config.app.executablePath !== "string" || !path.isAbsolute(config.app.executablePath)) {
    throw new Error("The update-session app identity is incomplete.");
  }
  if (config.platform === "win32" &&
      (typeof config.app.startTimeFileTimeUtc !== "string" || !/^\d{16,20}$/u.test(config.app.startTimeFileTimeUtc))) {
    throw new Error("The Windows app start time is invalid.");
  }
  if (config.platform === "darwin" &&
      (typeof config.app.startToken !== "string" || !config.app.startToken ||
       typeof config.app.bundleId !== "string" || !/^[A-Za-z0-9.-]+$/u.test(config.app.bundleId) ||
       typeof config.app.appPath !== "string" || !path.isAbsolute(config.app.appPath))) {
    throw new Error("The macOS app identity is incomplete.");
  }
  const allowedEntries = config.platform === "win32"
    ? new Set(["Enable-ChatGPTRemote.ps1", "CodexRemoteMobileProject\\MobileProjectStartup.ps1"])
    : new Set(["MobileProjectView-macOS-arm64.sh"]);
  if (!allowedEntries.has(config.relaunch?.entryPointRelative)) {
    throw new Error("The update-session relaunch entry point is not allowed.");
  }
  return config;
}

class PlatformAdapter {
  constructor(config, dependencies = {}) {
    this.config = config;
    this.run = dependencies.runCommand ?? runCommand;
    this.spawn = dependencies.spawn ?? spawn;
  }

  async #platform(action) {
    if (this.config.platform === "win32") {
      const shell = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
      const result = await this.run(shell, [
        "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", this.config.platformHelperPath, "-Action", action,
        "-ConfigPath", this.config.configPath,
      ], { timeoutMs: 45_000 });
      return parseLastJson(result.stdout);
    }
    const result = await this.run("/bin/zsh", [this.config.platformHelperPath, action, this.config.configPath], { timeoutMs: 45_000 });
    return parseLastJson(result.stdout);
  }

  async probe() {
    const result = await this.#platform("Probe");
    return result.running === true;
  }

  isAlive() {
    try {
      process.kill(this.config.app.pid, 0);
      return true;
    } catch (error) {
      return error?.code === "EPERM";
    }
  }

  async closeGracefully() {
    const result = await this.#platform("Close");
    return result.closed === true;
  }

  async relaunch() {
    const entry = path.join(this.config.installRoot, this.config.relaunch.entryPointRelative);
    const handoffPath = path.join(this.config.sessionDirectory, "relaunch-handoff.json");
    try { fs.rmSync(handoffPath, { force: true }); } catch {}
    let command;
    let args;
    let env = { ...process.env };
    if (this.config.platform === "win32") {
      command = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
      args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", entry];
      if (this.config.relaunch.entryPointRelative.endsWith("MobileProjectStartup.ps1")) args.push("-Action", "Run");
      if (this.config.relaunch.useProxy === true) args.push("-UseProxy");
      args.push("-UpdateResume", "-SkipUpdateCheckOnce", "-RelaunchHandoffPath", handoffPath);
    } else {
      command = "/bin/zsh";
      args = [entry, this.config.relaunch.startupMode === true ? "startup" : "enable"];
      env.CODEX_REMOTE_SKIP_UPDATE_CHECK_ONCE = "1";
      env.CODEX_REMOTE_SKIP_STARTUP_DELAY_ONCE = "1";
      env.CODEX_REMOTE_RELAUNCH_HANDOFF_PATH = handoffPath;
      env.CODEX_REMOTE_DEBUG_PORT = String(this.config.rendererPort);
      for (const [name, value] of Object.entries(this.config.relaunch.environment ?? {})) {
        if (["CODEX_APP_NAME", "CODEX_REMOTE_PEER_NAME", "CODEX_STARTUP_REQUIRED_PATH"].includes(name) && typeof value === "string") {
          env[name] = value;
        }
      }
    }
    const child = this.spawn(command, args, { cwd: this.config.installRoot, detached: true, env, stdio: "ignore", windowsHide: true });
    const spawned = new Promise((resolve, reject) => {
      child.once?.("spawn", resolve);
      child.once?.("error", reject);
      if (Number.isInteger(child.pid) && child.pid > 0 && typeof child.once !== "function") resolve();
    });
    let spawnTimer;
    try {
      await Promise.race([
        spawned,
        new Promise((_, reject) => {
          spawnTimer = setTimeout(() => reject(new Error("The updated launcher did not start.")), 10_000);
          spawnTimer.unref?.();
        }),
      ]);
    } finally {
      clearTimeout(spawnTimer);
    }
    child.unref?.();
    const deadline = Date.now() + 90_000;
    while (Date.now() < deadline) {
      try {
        const handoff = JSON.parse(fs.readFileSync(handoffPath, "utf8"));
        if (handoff?.ready === true && handoff.entryPointRelative === this.config.relaunch.entryPointRelative) {
          return { command, args: [...args], entry, handoffPath };
        }
      } catch {}
      if (child.exitCode !== null && child.exitCode !== undefined) {
        throw new Error(`The updated launcher exited before readiness handoff (exit ${child.exitCode}).`);
      }
      await sleep(250);
    }
    throw new Error("The updated launcher did not report readiness within 90 seconds.");
  }

  async notifyFailure(message) {
    const safe = cleanMessage(message, "The update could not be completed.");
    try {
      if (this.config.platform === "win32") {
        const shell = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        await this.run(shell, ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
          this.config.platformHelperPath, "-Action", "Notify", "-ConfigPath", this.config.configPath, "-Message", safe], { timeoutMs: 15_000 });
      } else {
        await this.run("/bin/zsh", [this.config.platformHelperPath, "notify", this.config.configPath, safe], { timeoutMs: 15_000 });
      }
    } catch {}
  }
}

class UpdaterAdapter {
  constructor(config, dependencies = {}) {
    this.config = config;
    this.run = dependencies.runCommand ?? runCommand;
  }

  async #invoke(action, release = null, preparedDirectory = null) {
    let command;
    let args;
    const env = { ...process.env };
    if (this.config.platform === "win32") {
      command = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
      args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", this.config.updaterPath,
        "-Action", action, "-InstallRoot", this.config.installRoot];
      if (process.env.CHATGPT_REMOTE_UPDATE_ALLOW_INSECURE === "1") args.push("-AllowInsecureTransport");
      if (release) args.push("-TargetVersion", release.version, "-ExpectedArchiveSha256", release.archiveSha256, "-PreparedDirectory", preparedDirectory);
    } else {
      command = "/bin/zsh";
      const macAction = { Check: "check", Prepare: "prepare", ApplyPrepared: "apply-prepared", Recover: "recover" }[action];
      args = [this.config.updaterPath, macAction];
      if (release) args.push("--target-version", release.version, "--expected-archive-sha256", release.archiveSha256, "--prepared-directory", preparedDirectory);
      env.CHATGPT_REMOTE_UPDATE_INSTALL_ROOT = this.config.installRoot;
    }
    const started = Date.now();
    try {
      const timeoutMs = action === "Check" ? 45_000 : action === "Prepare" ? 240_000 : 180_000;
      const result = await this.run(command, args, { env, timeoutMs });
      this.config.log?.("updater", { action, durationMs: Date.now() - started, ok: true });
      return parseLastJson(result.stdout);
    } catch (error) {
      this.config.log?.("updater", { action, durationMs: Date.now() - started, ok: false, error: cleanMessage(error?.message) });
      throw error;
    }
  }

  check() { return this.#invoke("Check"); }
  prepare(release, directory) { return this.#invoke("Prepare", release, directory); }
  applyPrepared(release, directory) { return this.#invoke("ApplyPrepared", release, directory); }
  recover() { return this.#invoke("Recover"); }
}

class UpdateSessionController {
  constructor(config, dependencies) {
    this.config = config;
    this.transport = dependencies.transport;
    this.updater = dependencies.updater;
    this.platform = dependencies.platform;
    this.sleep = dependencies.sleep ?? sleep;
    this.removePrepared = dependencies.removePrepared ?? ((directory) => safeRemovePrepared(config, directory));
    this.isWritable = dependencies.isWritable ?? (() => testWritable(config.installRoot));
    this.status = canonicalStatus({ state: "unavailable", message: "Update status is starting." });
    this.release = null;
    this.checkPromise = null;
    this.operationPromise = null;
    this.queueRequestPromise = null;
    this.generation = 0;
    this.handledRequests = new Map();
    this.closingInitiated = false;
    this.stopping = false;
    this.lastStrictProbeAt = 0;
    this.monitorPromise = null;
  }

  async setStatus(value) {
    this.status = canonicalStatus(value);
    try { await this.transport.publish(this.status); }
    catch (error) {
      if (!this.closingInitiated) throw error;
      this.config.log?.("status-publish", { state: this.status.state, error: cleanMessage(error?.message) });
    }
    return this.status;
  }

  async check(manual = false, fromQueue = false) {
    if (this.operationPromise || (this.queueRequestPromise && !fromQueue)) return this.status;
    if (!manual && this.config.autoCheckEnabled !== true) {
      return this.setStatus({ state: "unavailable", message: "Automatic update checks are disabled. Use Check to check manually." });
    }
    if (this.checkPromise) return this.checkPromise;
    if (["closing", "updating", "restarting"].includes(this.status.state)) return this.status;
    this.checkPromise = (async () => {
      await this.setStatus({ state: "checking", message: "Checking for an update…" });
      try {
        const result = await this.updater.check();
        if (typeof result?.available !== "boolean" || !validVersion(result.localVersion) ||
            (result.available && (!validVersion(result.latestVersion) || !validSha256(result.archiveSha256)))) {
          throw new Error("The updater returned an invalid check result.");
        }
        if (!result.available) {
          this.release = null;
          return this.setStatus({ state: "current", version: result.localVersion, message: "The installed version is current." });
        }
        this.release = Object.freeze({ version: result.latestVersion, archiveSha256: result.archiveSha256.toLowerCase() });
        if (!this.isWritable()) {
          return this.setStatus({
            state: "unavailable", version: this.release.version,
            message: "An update is available, but this install is not writable. Update it manually from an administrator session.",
          });
        }
        return this.setStatus({ state: "available", version: this.release.version, message: "An update is available.", canQueue: true });
      } catch (error) {
        return this.setStatus({ state: "error", message: cleanMessage(error?.message, "The update check failed.") });
      } finally {
        this.checkPromise = null;
      }
    })();
    return this.checkPromise;
  }

  async request(action, requestId) {
    if (!REQUEST_ACTIONS.has(action)) throw new Error("Unsupported update action.");
    if (this.handledRequests.has(requestId)) return this.handledRequests.get(requestId);
    const promise = (async () => {
      if (action === "check") return this.check(true);
      if (action === "queue") return this.queue();
      return this.cancel();
    })();
    this.handledRequests.set(requestId, promise);
    if (this.handledRequests.size > 128) this.handledRequests.delete(this.handledRequests.keys().next().value);
    return promise;
  }

  async queue() {
    if (this.queueRequestPromise) return this.queueRequestPromise;
    this.queueRequestPromise = (async () => {
      if (this.operationPromise) return this.status;
      if (!this.release || this.status.canQueue !== true) {
        await this.check(true, true);
        if (this.operationPromise || !this.release || this.status.canQueue !== true) return this.status;
      }
      const release = this.release;
      const generation = ++this.generation;
      const preparedDirectory = path.join(this.config.sessionDirectory, "prepared", release.version.replace(/[^A-Za-z0-9._-]/gu, "_"));
      this.operationPromise = this.#runQueuedUpdate(generation, release, preparedDirectory)
        .finally(() => { this.operationPromise = null; });
      return this.status;
    })().finally(() => { this.queueRequestPromise = null; });
    return this.queueRequestPromise;
  }

  async cancel() {
    if (this.status.canCancel !== true || !this.operationPromise) return this.status;
    this.generation += 1;
    return this.setStatus({
      state: "preparing",
      version: this.release?.version ?? this.status.version,
      message: "Cancelling the queued update after preparation settles…",
    });
  }

  async #runQueuedUpdate(generation, release, preparedDirectory) {
    let appClosed = false;
    let applied = false;
    let recovered = false;
    let relaunchAttempted = false;
    let retainPrepared = false;
    let retainedDirectory = preparedDirectory;
    try {
      this.removePrepared(preparedDirectory);
      await this.setStatus({ state: "preparing", version: release.version, message: "Downloading and verifying the update…", canCancel: true });
      const prepared = await this.updater.prepare(release, preparedDirectory);
      if (prepared?.prepared !== true || prepared.version !== release.version ||
          String(prepared.archiveSha256).toLowerCase() !== release.archiveSha256) {
        throw new Error("The prepared update did not match the pinned release.");
      }
      if (typeof prepared.preparedPath !== "string" || !path.isAbsolute(prepared.preparedPath)) {
        throw new Error("The updater returned an invalid prepared path.");
      }
      retainedDirectory = path.resolve(prepared.preparedPath);
      const preparedRoot = path.resolve(this.config.sessionDirectory, "prepared") + path.sep;
      const retainedComparison = this.config.platform === "win32" ? retainedDirectory.toLowerCase() : retainedDirectory;
      const rootComparison = this.config.platform === "win32" ? preparedRoot.toLowerCase() : preparedRoot;
      if (!retainedComparison.startsWith(rootComparison)) {
        throw new Error("The updater returned a prepared path outside this update session.");
      }
      if (generation !== this.generation || this.stopping) {
        this.removePrepared(retainedDirectory);
        if (!this.stopping) {
          await this.setStatus({ state: "available", version: release.version, message: "The queued update was cancelled.", canQueue: true });
        }
        return;
      }
      await this.setStatus({ state: "queued", version: release.version, message: "Update verified. Waiting for tasks to become idle…", canCancel: true });
      while (generation === this.generation && !this.stopping) {
        let activity;
        try { activity = await this.transport.queryActivity(); }
        catch (error) { activity = { known: false, busy: false, reason: cleanMessage(error?.message) }; }
        if (activity.known !== true) {
          await this.setStatus({ state: "queued", version: release.version, message: cleanMessage(activity.reason, "Waiting for authoritative task activity…"), canCancel: true });
          await this.sleep(this.config.activityPollMs ?? 2000);
          continue;
        }
        if (activity.busy) {
          await this.setStatus({ state: "queued", version: release.version, message: cleanMessage(activity.reason, "Waiting for active tasks to finish…"), canCancel: true });
          await this.sleep(this.config.activityPollMs ?? 2000);
          continue;
        }
        await this.sleep(this.config.idleRecheckMs ?? 1000);
        const confirmed = await this.transport.queryActivity().catch((error) => ({ known: false, busy: false, reason: cleanMessage(error?.message) }));
        if (confirmed.known === true && confirmed.busy === false) break;
      }
      if (generation !== this.generation || this.stopping) {
        this.removePrepared(retainedDirectory);
        if (!this.stopping) {
          await this.setStatus({ state: "available", version: release.version, message: "The queued update was cancelled.", canQueue: true });
        }
        return;
      }
      if (!this.isWritable()) {
        await this.setStatus({
          state: "unavailable", version: release.version,
          message: "The install is no longer writable and renameable. Update it manually from an administrator session.",
        });
        return;
      }
      await this.setStatus({ state: "closing", version: release.version, message: "Closing ChatGPT to install the verified update…" });
      this.closingInitiated = true;
      this.transport.setClosingExpected?.(true);
      if (await this.platform.closeGracefully() !== true) throw new Error("ChatGPT refused the graceful close request; the update was not applied.");
      appClosed = true;
      await this.setStatus({ state: "updating", version: release.version, message: "Installing the verified update…" });
      const result = await this.updater.applyPrepared(release, retainedDirectory);
      if (result?.updated !== true || result.version !== release.version ||
          String(result.archiveSha256).toLowerCase() !== release.archiveSha256) {
        throw new Error("The updater did not confirm the pinned release was installed.");
      }
      applied = true;
      const recovery = await this.updater.recover();
      if (recovery?.integrityValid !== true) throw new Error("Post-update integrity verification failed; relaunch was blocked.");
      recovered = true;
      await this.setStatus({ state: "restarting", version: release.version, message: "Restarting ChatGPT…" });
      relaunchAttempted = true;
      await this.platform.relaunch();
      this.stopping = true;
    } catch (error) {
      if (!appClosed) {
        this.closingInitiated = false;
        this.transport.setClosingExpected?.(false);
      }
      if (appClosed && !recovered && error?.commandTreeTerminationUnverified === true) {
        retainPrepared = true;
      } else if (appClosed && !recovered) {
        try {
          const recovery = await this.updater.recover();
          if (recovery?.integrityValid !== true) throw new Error("Recovery did not prove installed-file integrity.");
          recovered = true;
        } catch (recoveryError) {
          retainPrepared = true;
          error = new Error(`${cleanMessage(error?.message, "Update failed")} Recovery failed: ${cleanMessage(recoveryError?.message, "unknown error")}`);
        }
      }
      if (appClosed && recovered && !relaunchAttempted) {
        try {
          relaunchAttempted = true;
          await this.platform.relaunch();
        } catch (relaunchError) {
          error = new Error(`${cleanMessage(error?.message, "Update failed")} Relaunch failed: ${cleanMessage(relaunchError?.message, "unknown error")}`);
        }
      }
      this.config.log?.("terminal-update-failure", {
        appClosed, applied, recovered, relaunchAttempted, retainedPrepared: retainPrepared,
        error: cleanMessage(error?.message),
      });
      if (appClosed) {
        await this.platform.notifyFailure?.(error?.message);
        this.stopping = true;
      }
      await this.setStatus({ state: "error", version: release.version, message: cleanMessage(error?.message, "The update failed.") }).catch(() => {});
    } finally {
      if (!retainPrepared) {
        try { this.removePrepared(retainedDirectory); } catch {}
        if (retainedDirectory !== preparedDirectory) {
          try { this.removePrepared(preparedDirectory); } catch {}
        }
      }
    }
  }

  async monitorApp() {
    if (this.monitorPromise) return this.monitorPromise;
    this.monitorPromise = (async () => {
      if (this.closingInitiated || this.stopping) return true;
      if (this.platform.isAlive?.() === false) {
        this.stopping = true;
        this.generation += 1;
        return false;
      }
      const now = Date.now();
      if (now - this.lastStrictProbeAt < (this.config.identityProbeIntervalMs ?? 60_000)) return true;
      this.lastStrictProbeAt = now;
      let running = false;
      try { running = await this.platform.probe(); } catch {}
      if (running) return true;
      this.stopping = true;
      this.generation += 1;
      return false;
    })().finally(() => { this.monitorPromise = null; });
    return this.monitorPromise;
  }
}

function testWritable(installRoot) {
  const marker = path.join(installRoot, `.chatgpt-remote-update-access-${process.pid}-${crypto.randomUUID()}`);
  const renamed = `${marker}.renamed`;
  let handle;
  try {
    if (fs.lstatSync(installRoot).isSymbolicLink()) return false;
    handle = fs.openSync(marker, "wx", 0o600);
    fs.closeSync(handle);
    handle = undefined;
    fs.renameSync(marker, renamed);
    fs.renameSync(renamed, marker);
    return true;
  } catch {
    return false;
  } finally {
    try { if (handle !== undefined) fs.closeSync(handle); } catch {}
    try { fs.rmSync(marker, { force: true }); } catch {}
    try { fs.rmSync(renamed, { force: true }); } catch {}
  }
}

function safeRemovePrepared(config, directory) {
  const root = path.resolve(config.sessionDirectory, "prepared");
  const candidate = path.resolve(directory);
  const normalize = (value) => config.platform === "win32" ? value.toLowerCase() : value;
  if (normalize(candidate) === normalize(root) || !normalize(candidate).startsWith(normalize(root + path.sep))) {
    throw new Error("Refusing to remove a path outside the update-session prepared root.");
  }
  for (const ancestor of [config.stateRoot, path.join(config.stateRoot, "sessions"), config.sessionDirectory, root]) {
    if (fs.existsSync(ancestor) && fs.lstatSync(ancestor).isSymbolicLink()) {
      throw new Error("Refusing to remove a prepared path through a symbolic link or junction.");
    }
  }
  let current = root;
  for (const component of path.relative(root, candidate).split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    if (fs.existsSync(current) && fs.lstatSync(current).isSymbolicLink()) {
      throw new Error("Refusing to remove a prepared path through a symbolic link or junction.");
    }
  }
  fs.rmSync(candidate, { force: true, recursive: true });
}

function writeLog(logPath, stage, detail = {}) {
  try {
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    fs.appendFileSync(logPath, `${JSON.stringify({ at: new Date().toISOString(), stage, ...detail })}\n`, "utf8");
  } catch {
    // Diagnostics must not change update safety decisions.
  }
}

function acquireLock(config) {
  const identity = `${config.platform}\0${config.app.pid}\0${config.app.startTimeFileTimeUtc ?? config.app.startToken}`;
  const lockRoot = path.join(config.stateRoot, "active");
  const lockPath = path.join(lockRoot, `${crypto.createHash("sha256").update(identity).digest("hex").slice(0, 24)}.lock`);
  const reclaimPath = `${lockPath}.reclaim`;
  fs.mkdirSync(lockRoot, { recursive: true });
  const take = () => {
    const handle = fs.openSync(lockPath, "wx", 0o600);
    fs.writeFileSync(handle, `${JSON.stringify({ pid: process.pid })}\n`, "utf8");
    fs.closeSync(handle);
  };
  try { take(); }
  catch (error) {
    if (error?.code !== "EEXIST") throw error;
    const reclaimToken = `${process.pid}-${crypto.randomUUID()}`;
    try {
      fs.mkdirSync(reclaimPath, { mode: 0o700 });
      fs.writeFileSync(path.join(reclaimPath, "owner"), reclaimToken, { encoding: "utf8", flag: "wx", mode: 0o600 });
    } catch (reclaimError) {
      if (reclaimError?.code === "EEXIST") return { acquired: false, lockPath };
      throw reclaimError;
    }
    try {
      let owner = null;
      try { owner = JSON.parse(fs.readFileSync(lockPath, "utf8")); } catch {}
      if (!Number.isInteger(owner?.pid) || owner.pid <= 0) return { acquired: false, lockPath };
      try {
        process.kill(owner.pid, 0);
        return { acquired: false, lockPath };
      } catch (probeError) {
        if (probeError?.code !== "ESRCH") return { acquired: false, lockPath };
      }
      try {
        fs.rmSync(lockPath, { force: true });
        take();
      } catch (takeError) {
        if (takeError?.code === "EEXIST") return { acquired: false, lockPath };
        throw takeError;
      }
    } finally {
      try {
        const ownerPath = path.join(reclaimPath, "owner");
        if (fs.readFileSync(ownerPath, "utf8") === reclaimToken) {
          fs.rmSync(ownerPath, { force: true });
          fs.rmdirSync(reclaimPath);
        }
      } catch {}
    }
  }
  return { acquired: true, lockPath };
}

async function main() {
  const configIndex = process.argv.indexOf("--config");
  if (configIndex < 0 || !process.argv[configIndex + 1] || !path.isAbsolute(process.argv[configIndex + 1])) {
    throw new Error("Usage: update-session.js --config <absolute-path> [--best-effort]");
  }
  const configPath = path.resolve(process.argv[configIndex + 1]);
  const config = ensureConfig(JSON.parse(fs.readFileSync(configPath, "utf8")));
  config.configPath = configPath;
  config.bestEffort = process.argv.includes("--best-effort");
  config.log = (stage, detail) => writeLog(config.logPath, stage, detail);
  const lock = acquireLock(config);
  if (!lock.acquired) return;
  let transport;
  let monitorTimer;
  let checkTimer;
  try {
    const running = await new PlatformAdapter(config).probe();
    if (!running) throw new Error("The exact ChatGPT process no longer exists.");
    const cdp = require(path.join(path.dirname(__filename), "cdp.js"));
    const nonce = crypto.randomBytes(32).toString("hex");
    transport = new CdpTransport(config, nonce, cdp);
    const updater = new UpdaterAdapter(config);
    const platform = new PlatformAdapter(config);
    const controller = new UpdateSessionController(config, { transport, updater, platform });
    controller.lastStrictProbeAt = Date.now();
    transport.onRequest((action, id) => controller.request(action, id));
    await transport.attach();
    await transport.publish(controller.status);
    if (config.autoCheckEnabled === true && config.skipInitialCheck !== true) {
      controller.check(false).catch(() => {});
    } else if (config.autoCheckEnabled === true) {
      let installedVersion = null;
      try {
        const value = fs.readFileSync(path.join(config.installRoot, "VERSION"), "utf8").trim();
        if (validVersion(value)) installedVersion = value;
      } catch {}
      await controller.setStatus({ state: "current", version: installedVersion, message: "The automatic update check was skipped once after restart." });
    } else {
      await controller.check(false);
    }
    monitorTimer = setInterval(async () => {
      if (!await controller.monitorApp()) {
        clearInterval(monitorTimer);
        clearInterval(checkTimer);
        await transport.close();
      }
    }, config.processPollMs ?? 1000);
    checkTimer = setInterval(() => {
      if (!controller.stopping && config.autoCheckEnabled === true) controller.check(false).catch(() => {});
    }, UPDATE_INTERVAL_MS);
    await new Promise((resolve) => {
      const poll = setInterval(() => {
        if (controller.stopping && !controller.operationPromise) {
          clearInterval(poll);
          resolve();
        }
      }, 250);
    });
  } finally {
    clearInterval(monitorTimer);
    clearInterval(checkTimer);
    await transport?.close();
    try { fs.rmSync(lock.lockPath, { force: true }); } catch {}
  }
}

module.exports = {
  BINDING_NAME,
  CdpTransport,
  PlatformAdapter,
  REQUEST_ACTIONS,
  STATUS_STATES,
  TARGET_URL,
  UpdateSessionController,
  UpdaterAdapter,
  acquireLock,
  bootstrapSource,
  canonicalStatus,
  ensureConfig,
  parseLastJson,
  runCommand,
  safeRemovePrepared,
  testWritable,
};

if (require.main === module) {
  main().catch((error) => {
    const bestEffort = process.argv.includes("--best-effort");
    process.stderr.write(`${cleanMessage(error?.message, "The update session failed.")}\n`);
    process.exitCode = bestEffort ? 0 : 1;
  });
}
