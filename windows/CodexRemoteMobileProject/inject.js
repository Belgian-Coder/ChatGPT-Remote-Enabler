"use strict";

const fs = require("node:fs");
const path = require("node:path");
const stableRoot = path.resolve(__dirname, "..", "CodexRemoteSimple");
const { connectTarget, discoverTargets, evaluate } = require(path.join(stableRoot, "runtime", "lib", "cdp.js"));

const LEGACY_STATE_PATH = path.join(__dirname, ".mobile-project-session.json");
const userStateRoot = process.env.LOCALAPPDATA
  || (process.platform === "darwin" && process.env.HOME ? path.join(process.env.HOME, "Library", "Application Support") : null)
  || process.env.XDG_STATE_HOME
  || (process.env.HOME ? path.join(process.env.HOME, ".local", "state") : null)
  || __dirname;
const STATE_PATH = path.join(userStateRoot, "CodexRemoteFeatures", "mobile-project-session.json");

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) values[argv[index]?.replace(/^--/u, "")] = argv[index + 1];
  const port = Number(values.port);
  const targetWaitMs = values["target-wait-ms"] === undefined ? 0 : Number(values["target-wait-ms"]);
  if (!Number.isSafeInteger(port) || port < 1024 || port > 65535) throw new Error("Invalid renderer port");
  if (!Number.isSafeInteger(targetWaitMs) || targetWaitMs < 0 || targetWaitMs > 30_000) throw new Error("Invalid target wait");
  if (!["auto-off", "auto-on", "auto-reconcile", "auto-remove", "enable", "disable", "probe"].includes(values.action)) throw new Error("Invalid action");
  return { action: values.action, localName: values["local-name"] || "Local", port, singleRemoteName: values["single-remote-name"] || null, targetWaitMs };
}

function readStates() {
  const states = [];
  for (const candidate of [STATE_PATH, LEGACY_STATE_PATH]) {
    try { states.push(JSON.parse(fs.readFileSync(candidate, "utf8"))); } catch {}
  }
  return states;
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function discoverRendererTarget(port, waitMs) {
  const attempts = Math.max(1, Math.floor(waitMs / 500) + 1);
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const targets = await discoverTargets(port, 5000);
    const target = targets.find((candidate) => candidate?.type === "page" && candidate.url === "app://-/index.html");
    if (target) return target;
    if (attempt < attempts) await delay(500);
  }
  throw new Error(waitMs > 0 ? `Exact Codex renderer target was not found after ${waitMs} ms` : "Exact Codex renderer target was not found");
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const target = await discoverRendererTarget(options.port, options.targetWaitMs);
  const client = await connectTarget(target, options.port, 5000);
  try {
    if (options.action === "enable") {
      for (const state of readStates()) {
        if (state?.port === options.port && typeof state.identifier === "string") {
          try { await client.call("Page.removeScriptToEvaluateOnNewDocument", { identifier: state.identifier }, 5000); } catch {}
        }
      }
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
      const prefix = `globalThis.__CODEX_REMOTE_MOBILE_CONFIG__ = Object.freeze(${JSON.stringify({ hostDisplayNames, localDisplayName: options.localName, singleRemoteDisplayName })});\n`;
      const source = prefix + payload;
      const persistent = await client.call("Page.addScriptToEvaluateOnNewDocument", { source }, 5000);
      const report = await evaluate(client, source, 10000);
      const validCounts = [report?.hosts, report?.projects, report?.tasks]
        .every((value) => Number.isInteger(value) && value >= 0);
      if (report?.active !== true || !validCounts) {
        if (typeof persistent?.identifier === "string") await client.call("Page.removeScriptToEvaluateOnNewDocument", { identifier: persistent.identifier }, 5000);
        throw new Error("Mobile project view did not return valid proof");
      }
      fs.mkdirSync(path.dirname(STATE_PATH), { recursive: true });
      fs.writeFileSync(STATE_PATH, `${JSON.stringify({ identifier: persistent.identifier, port: options.port, version: 43 }, null, 2)}\n`, "utf8");
      try { fs.rmSync(LEGACY_STATE_PATH, { force: true }); } catch {}
      process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report })}\n`);
      return;
    }
    if (options.action === "disable") {
      const report = await evaluate(client, "globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.uninstall?.() ?? { active:false, version:null }", 5000);
      for (const state of readStates()) {
        if (state?.port === options.port && typeof state.identifier === "string") {
          try { await client.call("Page.removeScriptToEvaluateOnNewDocument", { identifier: state.identifier }, 5000); } catch {}
        }
      }
      for (const candidate of [STATE_PATH, LEGACY_STATE_PATH]) {
        try { fs.rmSync(candidate, { force: true }); } catch {}
      }
      process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report })}\n`);
      return;
    }
    if (options.action === "auto-on" || options.action === "auto-off") {
      const enabled = options.action === "auto-on";
      const report = await evaluate(client, `globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.setAutoRegistration?.(${JSON.stringify(enabled)}) ?? { active:false, version:null }`, 5000);
      process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report })}\n`);
      return;
    }
    if (options.action === "auto-remove") {
      const result = await evaluate(client, "globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.removeAllAutoRegistered?.() ?? { removed:0 }", 30000);
      const report = await evaluate(client, "globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.probe?.() ?? { active:false, version:null }", 5000);
      process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report, result })}\n`);
      return;
    }
    if (options.action === "auto-reconcile") {
      const result = await evaluate(client, "globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.reconcileAutoRegisteredProjects?.() ?? { removed:0 }", 30000);
      const report = await evaluate(client, "globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.probe?.() ?? { active:false, version:null }", 5000);
      process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report, result })}\n`);
      return;
    }
    const report = await evaluate(client, "globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.probe?.() ?? { active:false, version:null }", 5000);
    process.stdout.write(`${JSON.stringify({ action: options.action, ok: true, report })}\n`);
  } finally {
    client.close();
  }
}

main().catch((error) => { process.stderr.write(`${error?.message || "Unexpected failure"}\n`); process.exitCode = 1; });
