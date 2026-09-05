#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Clean-room contributors

"use strict";

const fs = require("node:fs");
const net = require("node:net");
const path = require("node:path");
const { connectTarget, discoverTargets, evaluate } = require("./lib/cdp.js");

const MAIN_OPTIONS_SLOT = "__CODEX_CLEANROOM_MAIN_OPTIONS__";
const TRANSIENT_RENDERER_CODES = new Set([
  "ECONNREFUSED",
  "ECONNRESET",
  "EPIPE",
  "DISCOVERY_ABORTED",
  "DISCOVERY_RESPONSE_FAILED",
  "DISCOVERY_TIMEOUT",
  "TARGET_NOT_FOUND",
  "TARGET_NOT_READY",
  "WEBSOCKET_CLOSED",
  "WEBSOCKET_CONNECT_FAILED",
  "WEBSOCKET_CONNECT_TIMEOUT",
  "WEBSOCKET_NOT_OPEN",
  "WEBSOCKET_SEND_FAILED",
]);

function isTransientRendererError(error) {
  if (TRANSIENT_RENDERER_CODES.has(error?.code)) return true;
  return error?.code === "CDP_PROTOCOL_ERROR"
    && error?.protocolCode === -32_000
    && /(?:context.*destroyed|cannot find context|execution context)/iu.test(error?.message ?? "");
}

function isMissingPersistentScriptError(error) {
  return error?.code === "CDP_PROTOCOL_ERROR"
    && /(?:no script|script.*not found|invalid.*(?:identifier|script)|unknown.*(?:identifier|script))/iu.test(error?.message ?? "");
}

function cliError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function parseInteger(value, name, minimum, maximum) {
  if (!/^[0-9]+$/u.test(value ?? "")) {
    throw cliError("ARGUMENT_INVALID", `${name} must be an integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw cliError("ARGUMENT_INVALID", `${name} is outside its allowed range`);
  }
  return parsed;
}

function parseArguments(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--help" || token === "-h") {
      return { help: true };
    }
    if (!token.startsWith("--")) {
      throw cliError("ARGUMENT_UNKNOWN", `Unexpected argument: ${token}`);
    }
    const name = token.slice(2);
    if (!["mode", "renderer-port", "main-port", "timeout-ms", "main-payload", "proxy-url"].includes(name) || values.has(name)) {
      throw cliError("ARGUMENT_UNKNOWN", `Unknown or duplicate option: ${token}`);
    }
    const value = argv[index + 1];
    if (value == null || value.startsWith("--")) {
      throw cliError("ARGUMENT_MISSING", `Missing value for ${token}`);
    }
    values.set(name, value);
    index += 1;
  }
  const mode = values.get("mode") ?? "full";
  if (mode !== "full" && mode !== "renderer" && mode !== "probe" && mode !== "probe-renderer") {
    throw cliError("ARGUMENT_INVALID", "mode must be exactly full, renderer, probe, or probe-renderer");
  }
  if ((mode === "renderer" || mode === "probe-renderer") && (values.has("main-port") || values.has("main-payload"))) {
    throw cliError("ARGUMENT_MODE_CONFLICT", `${mode} mode forbids main Inspector options`);
  }
  if (mode === "probe" && values.has("main-payload")) {
    throw cliError("ARGUMENT_MODE_CONFLICT", "probe mode forbids payload options");
  }
  if (mode !== "full" && values.has("proxy-url")) {
    throw cliError("ARGUMENT_MODE_CONFLICT", "proxy-url is only valid in full mode");
  }
  const requiredOptions = mode === "full"
    ? ["renderer-port", "main-port", "timeout-ms", "main-payload"]
    : mode === "probe"
      ? ["renderer-port", "main-port", "timeout-ms"]
      : ["renderer-port", "timeout-ms"];
  for (const required of requiredOptions) {
    if (!values.has(required)) {
      throw cliError("ARGUMENT_MISSING", `Required option is missing: --${required}`);
    }
  }
  const parsed = {
    help: false,
    mode,
    rendererPort: parseInteger(values.get("renderer-port"), "renderer port", 1, 65_535),
    timeoutMs: parseInteger(values.get("timeout-ms"), "timeout", 500, 300_000),
  };
  if (mode === "full" || mode === "probe") {
    parsed.mainPort = parseInteger(values.get("main-port"), "main port", 1, 65_535);
    if (parsed.mainPort === parsed.rendererPort) {
      throw cliError("ARGUMENT_INVALID", "main and renderer ports must be distinct");
    }
    if (mode === "full") {
      parsed.mainPayload = path.resolve(values.get("main-payload"));
      if (values.has("proxy-url")) parsed.proxyUrl = values.get("proxy-url");
    }
  }
  return parsed;
}

function remaining(deadline) {
  const value = deadline - Date.now();
  if (value < 25) {
    throw cliError("DEADLINE_EXCEEDED", "Compatibility bridge timed out");
  }
  return value;
}

function chooseTarget(targets, kind) {
  if (kind === "renderer") {
    const exactUrl = targets.find(
      (candidate) =>
        (candidate.type === "page" || candidate.type === "webview") && candidate.url === "app://-/index.html",
    );
    if (exactUrl) {
      return exactUrl;
    }
    throw cliError("TARGET_NOT_FOUND", "No page or webview target with the exact Codex renderer URL was found");
  }

  const preferences = ["node", "other"];
  for (const type of preferences) {
    const target = targets.find((candidate) => candidate.type === type);
    if (target) {
      return target;
    }
  }
  const fallback = targets[0];
  if (!fallback) {
    throw cliError("TARGET_NOT_FOUND", `No ${kind} debugger target was found`);
  }
  return fallback;
}

async function waitForTarget(port, kind, deadline) {
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const targets = await discoverTargets(port, Math.min(1_000, remaining(deadline)));
      return chooseTarget(targets, kind);
    } catch (error) {
      lastError = error;
      await delay(Math.min(75, Math.max(1, deadline - Date.now())));
    }
  }
  const error = cliError("TARGET_NOT_READY", `Timed out waiting for the ${kind} debugger target`);
  error.cause = lastError;
  throw error;
}

function sanitizeReport(value, depth = 0) {
  if (depth > 6) {
    return "[truncated]";
  }
  if (value === null || typeof value === "boolean" || typeof value === "number") {
    return value;
  }
  if (typeof value === "string") {
    return value.slice(0, 300);
  }
  if (Array.isArray(value)) {
    return value.slice(0, 50).map((item) => sanitizeReport(item, depth + 1));
  }
  if (typeof value === "object") {
    const output = {};
    for (const [key, child] of Object.entries(value).slice(0, 100)) {
      if (/(?:private|secret|token|signature|signedPayload|cipher|credential)/iu.test(key)) {
        output[key] = "[redacted]";
      } else {
        output[key] = sanitizeReport(child, depth + 1);
      }
    }
    return output;
  }
  return String(value).slice(0, 100);
}

function readPayload(payloadPath) {
  let stat;
  try {
    stat = fs.statSync(payloadPath);
  } catch {
    throw cliError("PAYLOAD_UNREADABLE", "Main payload file cannot be read");
  }
  if (!stat.isFile() || stat.size === 0 || stat.size > 4 * 1024 * 1024) {
    throw cliError("PAYLOAD_INVALID", "Main payload must be a non-empty file no larger than 4 MiB");
  }
  try {
    return fs.readFileSync(payloadPath, "utf8");
  } catch {
    throw cliError("PAYLOAD_UNREADABLE", "Main payload file cannot be read");
  }
}

function injectionExpression(source, runtimeOptions = {}) {
  const options = {
    inject: true,
    inspectorCloseDelayMs: 500,
    scheduleInspectorClose: true,
  };
  if (runtimeOptions.proxyUrl != null) options.proxyUrl = runtimeOptions.proxyUrl;
  return [
    "(() => {",
    `  globalThis[${JSON.stringify(MAIN_OPTIONS_SLOT)}] = ${JSON.stringify(options)};`,
    "  try {",
    `    return (0, eval)(${JSON.stringify(source)});`,
    "  } finally {",
    `    delete globalThis[${JSON.stringify(MAIN_OPTIONS_SLOT)}];`,
    "  }",
    "})()",
  ].join("\n");
}

function checkPortOnce(port, timeoutMs = 300) {
  return new Promise((resolve) => {
    const socket = net.createConnection({ family: 4, host: "127.0.0.1", port });
    let settled = false;
    const done = (result) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(result);
    };
    socket.setTimeout(timeoutMs, () => done({ state: "timeout" }));
    socket.once("connect", () => done({ state: "open" }));
    socket.once("error", (error) => done({ code: error?.code ?? "UNKNOWN", state: "error" }));
  });
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function waitForExplicitRefusal(port, timeoutMs) {
  const startedAt = Date.now();
  const deadline = startedAt + timeoutMs;
  let attempts = 0;
  let lastState = "unknown";
  while (Date.now() < deadline) {
    attempts += 1;
    const result = await checkPortOnce(port, Math.min(300, Math.max(25, deadline - Date.now())));
    lastState = result.code ?? result.state;
    if (result.state === "error" && result.code === "ECONNREFUSED") {
      return { attempts, code: "ECONNREFUSED", confirmed: true, elapsedMs: Date.now() - startedAt };
    }
    await delay(Math.min(75, Math.max(1, deadline - Date.now())));
  }
  const error = cliError("INSPECTOR_NOT_CLOSED", "Main Inspector port did not reach explicit ECONNREFUSED");
  error.lastState = lastState;
  throw error;
}

async function installMainPayload(options, source, deadline) {
  const target = await waitForTarget(options.mainPort, "main", deadline);
  const client = await connectTarget(target, options.mainPort, remaining(deadline));
  let report;
  try {
    await client.call("Runtime.enable", {}, remaining(deadline));
    report = await evaluate(client, injectionExpression(source, options), remaining(deadline), false);
  } finally {
    client.close();
  }
  const closure = await waitForExplicitRefusal(options.mainPort, remaining(deadline));
  return { closure, report: sanitizeReport(report) };
}

async function waitForRendererProof(client, deadline, dependencies = {}) {
  const evaluateRenderer = dependencies.evaluate ?? evaluate;
  while (Date.now() < deadline) {
    const probe = await evaluateRenderer(
      client,
      "globalThis.__CODEX_STATSIG_GATE_BRIDGE__?.scan?.() ?? null",
      remaining(deadline),
    );
    if (
      probe?.proof === true
      && probe?.targetGate === "782640499"
      && probe?.remoteConnectionsGate === "4114442250"
      && probe?.remoteConnectionsAllTrue === true
    ) {
      return sanitizeReport(probe);
    }
    await delay(Math.min(100, Math.max(1, deadline - Date.now())));
  }
  throw cliError("RENDERER_PROBE_FAILED", "Renderer payload did not prove the target gate override before timeout");
}

async function installRendererPayload(options, source, deadline, dependencies = {}) {
  const waitForRendererTarget = dependencies.waitForTarget ?? waitForTarget;
  const connectRendererTarget = dependencies.connectTarget ?? connectTarget;
  const evaluateRenderer = dependencies.evaluate ?? evaluate;
  const staleIdentifiers = dependencies.staleIdentifiers ?? new Set();
  const target = await waitForRendererTarget(options.rendererPort, "renderer", deadline);
  if (target?.url !== "app://-/index.html" || (target?.type !== "page" && target?.type !== "webview")) {
    throw cliError("TARGET_NOT_FOUND", "Renderer target must be the exact Codex page or webview URL");
  }
  const client = await connectRendererTarget(target, options.rendererPort, remaining(deadline));
  let persistentIdentifier = null;
  try {
    await client.call("Runtime.enable", {}, remaining(deadline));
    await client.call("Page.enable", {}, remaining(deadline));
    for (const identifier of [...staleIdentifiers]) {
      try {
        await client.call("Page.removeScriptToEvaluateOnNewDocument", { identifier }, remaining(deadline));
        staleIdentifiers.delete(identifier);
      } catch (error) {
        if (isMissingPersistentScriptError(error)) {
          staleIdentifiers.delete(identifier);
          continue;
        }
        throw error;
      }
    }
    const persistent = await client.call("Page.addScriptToEvaluateOnNewDocument", { source }, remaining(deadline));
    if (typeof persistent?.identifier !== "string" || persistent.identifier.length === 0) {
      throw cliError("PERSISTENT_SCRIPT_INVALID", "Debugger did not return a persistent renderer script identifier");
    }
    persistentIdentifier = persistent.identifier;
    const installReport = await evaluateRenderer(client, source, remaining(deadline));
    const probe = await waitForRendererProof(client, deadline, dependencies);
    return {
      currentDocument: {
        installed: installReport?.targetGate === "782640499"
          && installReport?.remoteConnectionsGate === "4114442250",
      },
      newDocumentScriptInstalled: true,
      probe,
      targetUrl: target.url,
    };
  } catch (error) {
    if (persistentIdentifier !== null) {
      try {
        const cleanupTimeoutMs = Math.max(25, Math.min(1_000, deadline - Date.now()));
        await client.call(
          "Page.removeScriptToEvaluateOnNewDocument",
          { identifier: persistentIdentifier },
          cleanupTimeoutMs,
        );
        staleIdentifiers.delete(persistentIdentifier);
      } catch (cleanupError) {
        if (isMissingPersistentScriptError(cleanupError)) staleIdentifiers.delete(persistentIdentifier);
        else staleIdentifiers.add(persistentIdentifier);
      }
    }
    throw error;
  } finally {
    client.close();
  }
}

async function installRendererPayloadWithRetry(options, source, deadline, dependencies = {}) {
  let lastTransientError = null;
  const staleIdentifiers = new Set();
  const attemptDependencies = { ...dependencies, staleIdentifiers };
  while (Date.now() < deadline) {
    try {
      return await installRendererPayload(options, source, deadline, attemptDependencies);
    } catch (error) {
      if (!isTransientRendererError(error)) throw error;
      lastTransientError = error;
      const waitMs = Math.min(100, Math.max(0, deadline - Date.now()));
      if (waitMs === 0) break;
      await delay(waitMs);
    }
  }
  throw lastTransientError ?? cliError("RENDERER_PROBE_FAILED", "Renderer payload did not become stable before timeout");
}

async function runBridge(options, dependencies = {}) {
  const deadline = Date.now() + options.timeoutMs;
  const loadPayload = dependencies.readPayload ?? readPayload;
  const installMain = dependencies.installMainPayload ?? installMainPayload;
  const mainSource = loadPayload(options.mainPayload);
  const rendererSource = loadPayload(path.join(__dirname, "renderer-payload.js"));
  let stage = "main-install";
  try {
    const main = await installMain(options, mainSource, deadline);
    stage = "renderer-install";
    const renderer = await installRendererPayloadWithRetry(options, rendererSource, deadline, dependencies);
    return {
      main: {
        inspectorPortClosed: main.closure,
        payloadReport: main.report,
      },
      ok: true,
      protocolVersion: 1,
      renderer,
    };
  } catch (error) {
    error.stage = error.stage ?? stage;
    throw error;
  }
}

async function runRendererBridge(options, dependencies = {}) {
  const deadline = Date.now() + options.timeoutMs;
  const loadPayload = dependencies.readPayload ?? readPayload;
  const rendererSource = loadPayload(path.join(__dirname, "renderer-payload.js"));
  let stage = "renderer-install";
  try {
    const renderer = await installRendererPayloadWithRetry(options, rendererSource, deadline, dependencies);
    return { ok: true, protocolVersion: 1, renderer };
  } catch (error) {
    error.stage = error.stage ?? stage;
    throw error;
  }
}

function probeMainResult(observation) {
  if (observation?.state === "error" && observation?.code === "ECONNREFUSED") {
    return { confirmed: true, code: "ECONNREFUSED" };
  }
  if (observation?.state === "open") {
    return { confirmed: false, code: "OPEN" };
  }
  if (observation?.state === "timeout") {
    return { confirmed: false, code: "TIMEOUT" };
  }
  throw cliError("MAIN_PORT_OBSERVATION_FAILED", "Main Inspector port observation failed operationally");
}

function probeRendererResult(value) {
  if (value === null) {
    return { proof: false, targetGate: null };
  }
  if (typeof value !== "object" || Array.isArray(value)) {
    throw cliError("PROBE_RESULT_INVALID", "Renderer probe returned malformed evidence");
  }
  const expectedKeys = [
    "allFalse",
    "checkMethods",
    "installedClients",
    "installedMethods",
    "passedMethods",
    "proof",
    "remoteConnectionsAllTrue",
    "remoteConnectionsGate",
    "remoteConnectionsPassedMethods",
    "scans",
    "structuredMethods",
    "targetGate",
  ];
  const keys = Object.keys(value);
  const countKeys = [
    "checkMethods",
    "installedClients",
    "installedMethods",
    "passedMethods",
    "remoteConnectionsPassedMethods",
    "scans",
    "structuredMethods",
  ];
  if (
    keys.length !== expectedKeys.length
    || expectedKeys.some((key) => !keys.includes(key))
    || typeof value.allFalse !== "boolean"
    || typeof value.proof !== "boolean"
    || value.targetGate !== "782640499"
    || typeof value.remoteConnectionsAllTrue !== "boolean"
    || value.remoteConnectionsGate !== "4114442250"
    || countKeys.some((key) => !Number.isSafeInteger(value[key]) || value[key] < 0)
    || value.installedMethods !== value.checkMethods + value.structuredMethods
    || value.passedMethods > value.checkMethods
    || value.remoteConnectionsPassedMethods > value.checkMethods
    || value.installedClients > value.installedMethods
    || value.allFalse !== (value.checkMethods > 0 && value.passedMethods === value.checkMethods)
    || value.remoteConnectionsAllTrue !== (
      value.checkMethods > 0 && value.remoteConnectionsPassedMethods === value.checkMethods
    )
    || value.proof !== (value.allFalse && value.remoteConnectionsAllTrue)
  ) {
    throw cliError("PROBE_RESULT_INVALID", "Renderer probe returned malformed evidence");
  }
  return {
    proof: value.proof,
    remoteConnectionsGate: value.remoteConnectionsGate,
    targetGate: value.targetGate,
  };
}

async function runProbeBridge(options, dependencies = {}) {
  const observePort = dependencies.checkPortOnce ?? checkPortOnce;
  const discoverRendererTargets = dependencies.discoverTargets ?? discoverTargets;
  const connectRendererTarget = dependencies.connectTarget ?? connectTarget;
  const evaluateRenderer = dependencies.evaluate ?? evaluate;
  const deadline = Date.now() + options.timeoutMs;
  let stage = options.mode === "probe-renderer" ? "probe-renderer-discovery" : "probe-main";
  try {
    const main = options.mode === "probe-renderer"
      ? { inspectorNotRequired: true }
      : { inspectorPortClosed: probeMainResult(await observePort(options.mainPort, Math.min(300, remaining(deadline)))) };
    stage = "probe-renderer-discovery";
    const targets = await discoverRendererTargets(options.rendererPort, remaining(deadline));
    if (!Array.isArray(targets)) {
      throw cliError("DISCOVERY_INVALID_SHAPE", "Renderer discovery did not return a target list");
    }
    const exactTargets = targets.filter(
      (candidate) =>
        candidate != null &&
        (candidate.type === "page" || candidate.type === "webview") &&
        candidate.url === "app://-/index.html",
    );
    if (exactTargets.length > 1) {
      throw cliError("TARGET_AMBIGUOUS", "More than one exact Codex renderer target was discovered");
    }
    if (exactTargets.length === 0) {
      return {
        ok: true,
        protocolVersion: 1,
        main,
        renderer: { targetUrl: null, probe: { proof: false, targetGate: null } },
      };
    }
    stage = "probe-renderer-connect";
    const target = exactTargets[0];
    const client = await connectRendererTarget(target, options.rendererPort, remaining(deadline));
    try {
      stage = "probe-renderer-evaluate";
      const raw = await evaluateRenderer(
        client,
        "globalThis.__CODEX_STATSIG_GATE_BRIDGE__?.probe?.() ?? null",
        remaining(deadline),
      );
      return {
        ok: true,
        protocolVersion: 1,
        main,
        renderer: { targetUrl: "app://-/index.html", probe: probeRendererResult(raw) },
      };
    } finally {
      client.close();
    }
  } catch (error) {
    error.stage = error.stage ?? stage;
    throw error;
  }
}

function safeError(error) {
  const code = typeof error?.code === "string" ? error.code : "UNEXPECTED_ERROR";
  const message = typeof error?.message === "string" ? error.message.replace(/[\r\n]+/gu, " ").slice(0, 300) : "Unexpected error";
  return { code, message };
}

async function main(argv = process.argv.slice(2)) {
  let options;
  try {
    options = parseArguments(argv);
    if (options.help) {
      process.stdout.write(`${JSON.stringify({
        ok: true,
        usage: "node orchestrator.js [--mode full|renderer|probe|probe-renderer] --renderer-port PORT --timeout-ms MS [--main-port PORT --main-payload FILE] [--proxy-url URL]",
      })}\n`);
      return 0;
    }
    const result = options.mode === "renderer"
      ? await runRendererBridge(options)
      : options.mode === "probe" || options.mode === "probe-renderer"
        ? await runProbeBridge(options)
        : await runBridge(options);
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return 0;
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ error: safeError(error), ok: false, stage: error?.stage ?? "arguments" })}\n`);
    return 1;
  }
}

if (require.main === module) {
  main().then((exitCode) => {
    process.exitCode = exitCode;
  });
}

module.exports = {
  checkPortOnce,
  chooseTarget,
  injectionExpression,
  parseArguments,
  runProbeBridge,
  runBridge,
  runRendererBridge,
  installRendererPayloadWithRetry,
  isTransientRendererError,
  waitForTarget,
  waitForExplicitRefusal,
};
