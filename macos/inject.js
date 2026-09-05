"use strict";

const fs = require("node:fs");
const path = require("node:path");
const stableRoot = __dirname;
const { connectTarget, discoverTargets, evaluate } = require(path.join(stableRoot, "runtime", "lib", "cdp.js"));

const LEGACY_STATE_PATH = path.join(__dirname, ".mobile-project-session.json");
const userStateRoot = process.env.LOCALAPPDATA
  || (process.platform === "darwin" && process.env.HOME ? path.join(process.env.HOME, "Library", "Application Support") : null)
  || process.env.XDG_STATE_HOME
  || (process.env.HOME ? path.join(process.env.HOME, ".local", "state") : null)
  || __dirname;
const STATE_PATH = path.join(userStateRoot, "CodexRemoteFeatures", "mobile-project-session.json");
const PROBE_TIMEOUT_MS = 10000;
const RETRYABLE_DISCOVERY_CODES = new Set([
  "ECONNREFUSED",
  "ECONNRESET",
  "EPIPE",
  "DISCOVERY_ABORTED",
  "DISCOVERY_HTTP_STATUS",
  "DISCOVERY_INVALID_JSON",
  "DISCOVERY_RESPONSE_FAILED",
  "DISCOVERY_TIMEOUT",
]);

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) values[argv[index]?.replace(/^--/u, "")] = argv[index + 1];
  const port = Number(values.port);
  const targetWaitMs = values["target-wait-ms"] === undefined ? 0 : Number(values["target-wait-ms"]);
  if (!Number.isSafeInteger(port) || port < 1024 || port > 65535) throw new Error("Invalid renderer port");
  if (!Number.isSafeInteger(targetWaitMs) || targetWaitMs < 0 || targetWaitMs > 30_000) throw new Error("Invalid target wait");
  if (!["archive-auto-off", "archive-auto-on", "archive-preview", "archive-run", "maintenance-auto-off", "maintenance-auto-on", "maintenance-preview", "maintenance-run", "auto-off", "auto-on", "auto-reconcile", "auto-remove", "enable", "disable", "probe"].includes(values.action)) throw new Error("Invalid action");
  return { action: values.action, localName: values["local-name"] || "Local", port, singleRemoteName: values["single-remote-name"] || null, targetWaitMs };
}

function normalizeRegistration(value) {
  if (
    typeof value?.identifier !== "string"
    || value.identifier.length === 0
    || !Number.isSafeInteger(value.port)
    || value.port < 1
    || value.port > 65_535
  ) return null;
  return {
    identifier: value.identifier,
    port: value.port,
    ...(Number.isSafeInteger(value.version) && value.version > 0 ? { version: value.version } : {}),
  };
}

function readSessionState(statePaths = [STATE_PATH, LEGACY_STATE_PATH]) {
  const registrations = new Map();
  for (const candidate of statePaths) {
    let parsed;
    try {
      parsed = JSON.parse(fs.readFileSync(candidate, "utf8"));
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw new Error(`Mobile project session state is unreadable: ${path.basename(candidate)}`);
    }
    const values = Array.isArray(parsed?.registrations) ? parsed.registrations : [parsed];
    for (const value of values) {
      const registration = normalizeRegistration(value);
      if (registration) {
        const key = `${registration.port}\0${registration.identifier}`;
        if (!registrations.has(key)) registrations.set(key, registration);
      }
    }
  }
  return [...registrations.values()];
}

function atomicWriteJson(targetPath, value) {
  fs.mkdirSync(path.dirname(targetPath), { recursive: true });
  const temporaryPath = path.join(
    path.dirname(targetPath),
    `.${path.basename(targetPath)}.${process.pid}.${Date.now()}.tmp`,
  );
  try {
    fs.writeFileSync(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, { encoding: "utf8", flag: "wx", mode: 0o600 });
    fs.renameSync(temporaryPath, targetPath);
  } finally {
    try { fs.rmSync(temporaryPath, { force: true }); } catch {}
  }
}

function persistSessionState(registrations, statePath = STATE_PATH, legacyPath = LEGACY_STATE_PATH) {
  if (registrations.length === 0) {
    fs.rmSync(statePath, { force: true });
    if (legacyPath !== statePath) fs.rmSync(legacyPath, { force: true });
    return;
  }
  atomicWriteJson(statePath, { registrations, schemaVersion: 2 });
  if (legacyPath !== statePath) fs.rmSync(legacyPath, { force: true });
}

function isMissingPersistentScriptError(error) {
  return error?.code === "CDP_PROTOCOL_ERROR"
    && /(?:no script|script.*not found|invalid.*(?:identifier|script)|unknown.*(?:identifier|script))/iu.test(error?.message ?? "");
}

async function removeRegistrations(client, registrations, port) {
  const failures = [];
  const pending = [];
  for (const registration of registrations) {
    if (registration.port !== port) {
      pending.push(registration);
      continue;
    }
    try {
      await client.call("Page.removeScriptToEvaluateOnNewDocument", { identifier: registration.identifier }, 5000);
    } catch (error) {
      if (isMissingPersistentScriptError(error)) continue;
      failures.push({ error, registration });
      pending.push(registration);
    }
  }
  return { failures, pending };
}

function throwCleanupFailure(failures) {
  if (failures.length === 0) return;
  const error = new Error(`Failed to remove ${failures.length} persistent mobile project script registration${failures.length === 1 ? "" : "s"}`);
  error.code = "PERSISTENT_SCRIPT_CLEANUP_FAILED";
  throw error;
}

function assertActiveReport(report, action) {
  if (report?.active !== true || !Number.isInteger(report?.version) || report.version < 1) {
    const error = new Error(`Mobile project view is inactive; ${action} was not applied`);
    error.code = "MOBILE_PROJECT_VIEW_INACTIVE";
    throw error;
  }
  return report;
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function exactRendererTarget(targets) {
  const exact = targets.filter(
    (candidate) => (candidate?.type === "page" || candidate?.type === "webview") && candidate.url === "app://-/index.html",
  );
  if (exact.length > 1) {
    const error = new Error("More than one exact Codex renderer target was found");
    error.code = "TARGET_AMBIGUOUS";
    throw error;
  }
  return exact[0] ?? null;
}

async function discoverRendererTarget(port, waitMs, dependencies = {}) {
  const discover = dependencies.discoverTargets ?? discoverTargets;
  const wait = dependencies.delay ?? delay;
  if (waitMs === 0) {
    const targets = await discover(port, 5000);
    const target = exactRendererTarget(targets);
    if (target) return target;
    throw new Error("Exact Codex renderer target was not found");
  }
  const deadline = Date.now() + waitMs;
  let lastError = null;
  for (;;) {
    const remaining = Math.max(1, deadline - Date.now());
    try {
      const targets = await discover(port, Math.min(1000, remaining));
      const target = exactRendererTarget(targets);
      if (target) return target;
    } catch (error) {
      if (!RETRYABLE_DISCOVERY_CODES.has(error?.code)) throw error;
      lastError = error;
    }
    if (Date.now() >= deadline) break;
    await wait(Math.min(250, Math.max(1, deadline - Date.now())));
  }
  const error = new Error(waitMs > 0 ? `Exact Codex renderer target was not found after ${waitMs} ms` : "Exact Codex renderer target was not found");
  error.cause = lastError;
  throw error;
}

function requiredApiCall(methodNames, args = []) {
  return `(() => { const api = globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__; const methods = ${JSON.stringify(methodNames)}; const method = methods.find((name) => typeof api?.[name] === "function"); if (api?.probe?.()?.active !== true || !method) throw new Error("Mobile project view command is unavailable"); return api[method](...${JSON.stringify(args)}); })()`;
}

async function activeProbe(client, action) {
  const report = await evaluate(client, "globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.probe?.() ?? { active:false, version:null }", PROBE_TIMEOUT_MS);
  return assertActiveReport(report, action);
}

function assertCommandResult(result, action) {
  if (result == null || typeof result !== "object" || Array.isArray(result)) {
    throw new Error(`Mobile project view returned invalid ${action} evidence`);
  }
  if (typeof result.error === "string" && result.error.length > 0) {
    throw new Error(`Mobile project view ${action} failed: ${result.error.slice(0, 240)}`);
  }
  return result;
}

async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  const target = await discoverRendererTarget(options.port, options.targetWaitMs);
  const client = await connectTarget(target, options.port, 5000);
  try {
    if (options.action === "enable") {
      const prior = readSessionState();
      const priorCleanup = await removeRegistrations(client, prior, options.port);
      persistSessionState(priorCleanup.pending);
      throwCleanupFailure(priorCleanup.failures);
      const payload = fs.readFileSync(path.join(__dirname, "renderer-mobile-project-view.js"), "utf8");
      let hostDisplayNames = {};
      let singleRemoteDisplayName = options.singleRemoteName;
      try {
        const candidate = JSON.parse(fs.readFileSync(path.join(__dirname, "host-names.json"), "utf8"));
        if (candidate && typeof candidate === "object" && !Array.isArray(candidate)) {
          hostDisplayNames = Object.fromEntries(Object.entries(candidate).filter(([key, value]) => typeof key === "string" && typeof value === "string"));
        }
      } catch {}
      try {
        const peers = JSON.parse(fs.readFileSync(path.join(__dirname, "host-peers.json"), "utf8"));
        const localEntry = Object.entries(peers).find(([name, value]) => name.localeCompare(options.localName, undefined, { sensitivity: "base" }) === 0 && typeof value === "string");
        if (!singleRemoteDisplayName && localEntry) singleRemoteDisplayName = localEntry[1];
      } catch {}
      let helperVersion = null;
      try {
        const candidate = fs.readFileSync(path.join(__dirname, "VERSION"), "utf8").trim();
        if (/^v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/u.test(candidate) && candidate.length <= 64) helperVersion = candidate;
      } catch {}
      const prefix = `globalThis.__CODEX_REMOTE_MOBILE_CONFIG__ = Object.freeze(${JSON.stringify({ hostDisplayNames, localDisplayName: options.localName, singleRemoteDisplayName, helperVersion })});\n`;
      const source = prefix + payload;
      const persistent = await client.call("Page.addScriptToEvaluateOnNewDocument", { source }, 5000);
      if (typeof persistent?.identifier !== "string" || !persistent.identifier) throw new Error("CDP did not return a persistent script identifier");
      const registration = { identifier: persistent.identifier, port: options.port };
      try {
        persistSessionState([...priorCleanup.pending, registration]);
        const report = await evaluate(client, source, 10000);
        const validCounts = [report?.hosts, report?.projects, report?.tasks]
          .every((value) => Number.isInteger(value) && value >= 0);
        if (report?.active !== true || !validCounts || !Number.isInteger(report?.version) || report.version < 1) throw new Error("Mobile project view did not return valid proof");
        registration.version = report.version;
        persistSessionState([...priorCleanup.pending, registration]);
        process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report })}\n`);
        return;
      } catch (error) {
        try { await evaluate(client, "globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.uninstall?.()", 5000); } catch {}
        const rollback = await removeRegistrations(client, [registration], options.port);
        persistSessionState([...priorCleanup.pending, ...rollback.pending]);
        if (rollback.failures.length > 0) error.message = `${error.message}; persistent registration cleanup is pending`;
        throw error;
      }
    }
    if (options.action === "disable") {
      let report = { active: false, version: null };
      let uninstallError = null;
      try {
        report = await evaluate(client, "globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.uninstall?.() ?? { active:false, version:null }", 5000);
      } catch (error) {
        uninstallError = error;
      }
      const cleanup = await removeRegistrations(client, readSessionState(), options.port);
      persistSessionState(cleanup.pending);
      throwCleanupFailure(cleanup.failures);
      if (cleanup.pending.length > 0) {
        const error = new Error("Persistent mobile project script registrations remain on another renderer port");
        error.code = "PERSISTENT_SCRIPT_CLEANUP_PENDING";
        throw error;
      }
      if (uninstallError) throw uninstallError;
      process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report })}\n`);
      return;
    }
    if (options.action === "auto-on" || options.action === "auto-off") {
      const enabled = options.action === "auto-on";
      const report = assertActiveReport(await evaluate(client, requiredApiCall(["setAutoRegistration"], [enabled]), 5000), options.action);
      process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report })}\n`);
      return;
    }
    if (["archive-auto-on", "archive-auto-off", "maintenance-auto-on", "maintenance-auto-off"].includes(options.action)) {
      const enabled = options.action.endsWith("-on");
      const report = assertActiveReport(await evaluate(client, requiredApiCall(["setAutoMaintenance", "setAutoArchive"], [enabled]), 5000), options.action);
      process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report })}\n`);
      return;
    }
    if (options.action === "archive-run" || options.action === "maintenance-run") {
      const result = assertCommandResult(await evaluate(client, requiredApiCall(["runAutoMaintenanceNow", "runAutoArchiveNow"]), 120000), options.action);
      const report = await activeProbe(client, options.action);
      process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report, result })}\n`);
      return;
    }
    if (options.action === "archive-preview" || options.action === "maintenance-preview") {
      const result = assertCommandResult(await evaluate(client, requiredApiCall(["previewAutoMaintenance", "previewAutoArchive"]), 120000), options.action);
      const report = await activeProbe(client, options.action);
      process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report, result })}\n`);
      return;
    }
    if (options.action === "auto-remove") {
      const result = assertCommandResult(await evaluate(client, requiredApiCall(["removeAllAutoRegistered"]), 30000), options.action);
      const report = await activeProbe(client, options.action);
      process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report, result })}\n`);
      return;
    }
    if (options.action === "auto-reconcile") {
      const result = assertCommandResult(await evaluate(client, requiredApiCall(["reconcileAutoRegisteredProjects"]), 30000), options.action);
      const report = await activeProbe(client, options.action);
      process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report, result })}\n`);
      return;
    }
    const report = await evaluate(client, "globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.probe?.() ?? { active:false, version:null }", PROBE_TIMEOUT_MS);
    process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report })}\n`);
  } finally {
    client.close();
  }
}

if (require.main === module) {
  main().catch((error) => { process.stderr.write(`${error?.message || "Unexpected failure"}\n`); process.exitCode = 1; });
}

module.exports = {
  assertActiveReport,
  atomicWriteJson,
  discoverRendererTarget,
  exactRendererTarget,
  main,
  normalizeRegistration,
  persistSessionState,
  readSessionState,
  removeRegistrations,
  requiredApiCall,
};
