"use strict";

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const stableRoot = path.resolve(__dirname, "..", "CodexRemoteSimple");
const { connectTarget, discoverTargets, evaluate } = require(path.join(stableRoot, "runtime", "lib", "cdp.js"));

const LEGACY_STATE_PATH = path.join(__dirname, ".mobile-project-session.json");
const userStateRoot = process.env.LOCALAPPDATA
  || (process.platform === "darwin" && process.env.HOME ? path.join(process.env.HOME, "Library", "Application Support") : null)
  || process.env.XDG_STATE_HOME
  || (process.env.HOME ? path.join(process.env.HOME, ".local", "state") : null)
  || __dirname;
const STATE_PATH = path.join(userStateRoot, "CodexRemoteFeatures", "mobile-project-session.json");
const INJECTION_SLOT = "__CODEX_REMOTE_MOBILE_INJECTION__";
const PROBE_TIMEOUT_MS = 10000;
const ENABLE_TARGET_WAIT_MS = 30000;
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
const RETRYABLE_CONNECT_CODES = new Set([
  ...RETRYABLE_DISCOVERY_CODES,
  "TARGET_NOT_FOUND",
  "WEBSOCKET_CLOSED",
  "WEBSOCKET_CONNECT_FAILED",
  "WEBSOCKET_CONNECT_TIMEOUT",
]);
const DEAD_REGISTRATION_PORT_CODES = new Set([
  "ECONNREFUSED",
  "ECONNRESET",
  "EPIPE",
  "DISCOVERY_ABORTED",
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

function rendererTargetWaitMilliseconds(action, requestedWaitMs) {
  return Math.max(action === "enable" ? ENABLE_TARGET_WAIT_MS : 5000, requestedWaitMs);
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
    ...(typeof value.token === "string" && /^[a-f0-9]{32}$/u.test(value.token) ? { token: value.token } : {}),
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

async function registrationPortState(port, dependencies = {}) {
  const discover = dependencies.discoverTargets ?? discoverTargets;
  try {
    const targets = await discover(port, dependencies.discoveryTimeoutMs ?? 1000);
    if (!Array.isArray(targets)) return "unknown";
    return exactRendererTarget(targets) ? "active" : "stale";
  } catch (error) {
    return DEAD_REGISTRATION_PORT_CODES.has(error?.code) ? "stale" : "unknown";
  }
}

async function removeRegistrations(client, registrations, port, dependencies = {}) {
  const failures = [];
  const pending = [];
  const stale = [];
  const portStates = new Map();
  for (const registration of registrations) {
    if (registration.port !== port) {
      if (!portStates.has(registration.port)) portStates.set(registration.port, registrationPortState(registration.port, dependencies));
      if (await portStates.get(registration.port) === "stale") stale.push(registration);
      else pending.push(registration);
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
  return { failures, pending, stale };
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

function targetNotFoundError(waitMs, cause = null) {
  const error = new Error(waitMs > 0 ? `Exact Codex renderer target was not found after ${waitMs} ms` : "Exact Codex renderer target was not found");
  error.code = "TARGET_NOT_FOUND";
  if (cause) error.cause = cause;
  return error;
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
    throw targetNotFoundError(0);
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
  throw targetNotFoundError(waitMs, lastError);
}

async function connectRendererTargetWithRetry(port, waitMs, dependencies = {}) {
  const connect = dependencies.connectTarget ?? connectTarget;
  const discoverRenderer = dependencies.discoverRendererTarget ?? discoverRendererTarget;
  const wait = dependencies.delay ?? delay;
  const deadline = Date.now() + waitMs;
  let lastError = null;
  for (;;) {
    const remaining = Math.max(1, deadline - Date.now());
    try {
      const target = await discoverRenderer(port, Math.min(1000, remaining), dependencies);
      return await connect(target, port, Math.min(2000, Math.max(1, deadline - Date.now())));
    } catch (error) {
      if (!RETRYABLE_CONNECT_CODES.has(error?.code)) throw error;
      lastError = error;
    }
    if (Date.now() >= deadline) {
      if (lastError?.code === "TARGET_NOT_FOUND") throw targetNotFoundError(waitMs, lastError);
      throw lastError;
    }
    await wait(Math.min(250, Math.max(1, deadline - Date.now())));
  }
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

async function disableRenderer(client, port, dependencies = {}) {
  const evaluateCall = dependencies.evaluate ?? evaluate;
  const readState = dependencies.readSessionState ?? readSessionState;
  const persistState = dependencies.persistSessionState ?? persistSessionState;
  let report = { active: false, version: null };
  let uninstallError = null;
  try {
    report = await evaluateCall(client, "globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.uninstall?.() ?? { active:false, version:null }", 5000);
  } catch (error) {
    uninstallError = error;
  }
  const cleanup = await removeRegistrations(client, readState(), port, dependencies);
  persistState(cleanup.pending);
  throwCleanupFailure(cleanup.failures);
  if (cleanup.pending.length > 0) {
    const error = new Error("Persistent mobile project script registrations remain on another renderer port");
    error.code = "PERSISTENT_SCRIPT_CLEANUP_PENDING";
    throw error;
  }
  if (uninstallError) throw uninstallError;
  return { report, stale: cleanup.stale };
}

async function enableRenderer(client, { port, payload, config }, dependencies = {}) {
  const readState = dependencies.readSessionState ?? readSessionState;
  const persistState = dependencies.persistSessionState ?? persistSessionState;
  const remove = dependencies.removeRegistrations ?? removeRegistrations;
  const evaluateCall = dependencies.evaluate ?? evaluate;
  const configText = JSON.stringify(config);
  const prior = readState();
  const current = prior.filter((registration) => registration.port === port);
  // The token and API object are created by the persistent script in this
  // renderer. A saved registration cannot prove reuse after a port is recycled.
  if (current.length === 1 && /^[a-f0-9]{32}$/u.test(current[0].token ?? "")) {
    try {
      const proof = await evaluateCall(client,
        `(() => { const api = globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__; const marker = globalThis[${JSON.stringify(INJECTION_SLOT)}]; return { matches: marker?.token === ${JSON.stringify(current[0].token)} && marker?.api === api && marker?.sourceText === ${JSON.stringify(payload)} && marker?.configText === ${JSON.stringify(configText)}, report: api?.probe?.() ?? null }; })()`, PROBE_TIMEOUT_MS);
      if (proof?.matches === true
        && proof.report?.active === true
        && proof.report?.readiness?.ready === true
        && Number.isInteger(proof.report.version)
        && proof.report.version === current[0].version) return proof.report;
    } catch {} // An unproven view follows the normal replacement path.
  }
  const priorCleanup = await remove(client, prior, port);
  persistState(priorCleanup.pending);
  throwCleanupFailure(priorCleanup.failures);
  const token = crypto.randomBytes(16).toString("hex");
  const expression = payload.replace(/^\s*"use strict";\s*/u, "").trim();
  if (!expression.startsWith("(() => {") || !expression.endsWith("})();")) {
    throw new Error("The mobile renderer source is not a supported installation expression");
  }
  const source = `globalThis.__CODEX_REMOTE_MOBILE_CONFIG__ = Object.freeze(${configText});\n`
    + `(() => { const report = ${expression}\n`
    + `const api = globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__;\n`
    + `return Promise.resolve(report).then((value) => {\n`
    + `  if (value?.active === true && globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__ === api) {\n`
    + `    globalThis[${JSON.stringify(INJECTION_SLOT)}] = Object.freeze({ token: ${JSON.stringify(token)}, sourceText: ${JSON.stringify(payload)}, configText: ${JSON.stringify(configText)}, api });\n`
    + `  }\n`
    + `  return value;\n`
    + `}); })()`;
  const persistent = await client.call("Page.addScriptToEvaluateOnNewDocument", { source }, 5000);
  if (typeof persistent?.identifier !== "string" || !persistent.identifier) throw new Error("CDP did not return a persistent script identifier");
  const registration = { identifier: persistent.identifier, port, token };
  try {
    persistState([...priorCleanup.pending, registration]);
    const report = await evaluateCall(client, source, 10000);
    const validCounts = [report?.hosts, report?.projects, report?.tasks]
      .every((value) => Number.isInteger(value) && value >= 0);
    if (report?.active !== true || !validCounts || !Number.isInteger(report?.version) || report.version < 1) throw new Error("Mobile project view did not return valid proof");
    registration.version = report.version;
    persistState([...priorCleanup.pending, registration]);
    return report;
  } catch (error) {
    try { await evaluateCall(client, "globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.uninstall?.()", 5000); } catch {}
    const rollback = await remove(client, [registration], port);
    persistState([...priorCleanup.pending, ...rollback.pending]);
    if (rollback.failures.length > 0) error.message = `${error.message}; persistent registration cleanup is pending`;
    throw error;
  }
}

async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  const client = await connectRendererTargetWithRetry(
    options.port,
    rendererTargetWaitMilliseconds(options.action, options.targetWaitMs),
  );
  try {
    if (options.action === "enable") {
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
        const candidate = fs.readFileSync(path.join(__dirname, "..", "VERSION"), "utf8").trim();
        if (/^v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/u.test(candidate) && candidate.length <= 64) helperVersion = candidate;
      } catch {}
      const config = { hostDisplayNames, localDisplayName: options.localName, singleRemoteDisplayName, helperVersion };
      const report = await enableRenderer(client, { port: options.port, payload, config });
      process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report })}\n`);
      return;
    }
    if (options.action === "disable") {
      const disabled = await disableRenderer(client, options.port);
      const staleRegistrations = disabled.stale.map(({ identifier, port }) => ({ identifier, port }));
      process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report: disabled.report, staleRegistrations })}\n`);
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
  connectRendererTargetWithRetry,
  discoverRendererTarget,
  exactRendererTarget,
  main,
  normalizeRegistration,
  persistSessionState,
  registrationPortState,
  readSessionState,
  removeRegistrations,
  rendererTargetWaitMilliseconds,
  requiredApiCall,
  disableRenderer,
  enableRenderer,
};
