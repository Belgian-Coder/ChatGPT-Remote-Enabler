"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const calls = [];
const client = {
  checkGate(gate) {
    calls.push(String(gate));
    return String(gate) === "unrelated-enabled";
  },
  checkGateWithExposureLoggingDisabled(gate) {
    calls.push(String(gate));
    return String(gate) === "unrelated-enabled";
  },
  getFeatureGate(gate) {
    return { enabled: false, gate: String(gate), value: false };
  },
};

const context = vm.createContext({
  __STATSIG__: { client },
  clearInterval,
  console,
  globalThis: null,
  setInterval,
});
context.globalThis = context;

const source = fs.readFileSync(path.join(__dirname, "..", "runtime", "renderer-payload.js"), "utf8");
const report = vm.runInContext(source, context, { filename: "renderer-payload.js" });

assert.equal(client.checkGate("782640499"), false);
assert.equal(client.checkGate("4114442250"), true);
assert.equal(client.checkGate("unrelated-enabled"), true);
assert.equal(client.checkGate("unrelated-disabled"), false);

const hiddenGate = client.getFeatureGate("782640499");
assert.equal(hiddenGate.value, false);
assert.equal(hiddenGate.enabled, false);

const remoteGate = client.getFeatureGate("4114442250");
assert.equal(remoteGate.value, true);
assert.equal(remoteGate.enabled, true);

assert.equal(report.proof, true);
assert.equal(report.targetGate, "782640499");
assert.equal(report.remoteConnectionsGate, "4114442250");
assert.equal(report.remoteConnectionsAllTrue, true);
assert.equal(context.__CODEX_STATSIG_GATE_BRIDGE__.version, 2);
assert.equal(calls.includes("782640499"), false);
assert.equal(calls.includes("4114442250"), false);

async function testOrchestratorProbeValidation() {
  const { parseArguments, runProbeBridge } = require("../runtime/orchestrator.js");
  const result = await runProbeBridge(
    { rendererPort: 41001, mainPort: 41002, timeoutMs: 30000 },
    {
      checkPortOnce: async () => ({ state: "error", code: "ECONNREFUSED" }),
      discoverTargets: async () => [
        {
          type: "page",
          url: "app://-/index.html",
          webSocketDebuggerUrl: "ws://127.0.0.1/fake",
        },
      ],
      connectTarget: async () => ({
        close: () => {},
      }),
      evaluate: async () => report,
    },
  );

  assert.equal(result.renderer.probe.proof, true);
  assert.equal(result.renderer.probe.targetGate, "782640499");
  assert.equal(result.renderer.probe.remoteConnectionsGate, "4114442250");

  const rendererOnlyOptions = parseArguments([
    "--mode", "probe-renderer", "--renderer-port", "41001", "--timeout-ms", "30000",
  ]);
  let mainPortObserved = false;
  const rendererOnly = await runProbeBridge(rendererOnlyOptions, {
    checkPortOnce: async () => {
      mainPortObserved = true;
      throw new Error("renderer-only probe must not inspect a main-process port");
    },
    discoverTargets: async () => [{
      type: "page",
      url: "app://-/index.html",
      webSocketDebuggerUrl: "ws://127.0.0.1/fake",
    }],
    connectTarget: async () => ({ close: () => {} }),
    evaluate: async () => report,
  });
  assert.equal(mainPortObserved, false);
  assert.equal(rendererOnly.main.inspectorNotRequired, true);
  assert.equal(rendererOnly.renderer.probe.proof, true);
  assert.throws(
    () => parseArguments(["--mode", "probe-renderer", "--renderer-port", "41001", "--main-port", "41002", "--timeout-ms", "30000"]),
    /forbids main Inspector options/u,
  );
}

async function testRendererInstallRetriesTransientReload() {
  const { runRendererBridge } = require("../runtime/orchestrator.js");
  let connections = 0;
  let closes = 0;
  const target = {
    type: "page",
    url: "app://-/index.html",
    webSocketDebuggerUrl: "ws://127.0.0.1/fake",
  };
  const result = await runRendererBridge(
    { rendererPort: 41001, timeoutMs: 3000 },
    {
      readPayload: () => "synthetic renderer payload",
      waitForTarget: async () => target,
      connectTarget: async () => {
        connections += 1;
        if (connections === 1) {
          return {
            call: async () => {
              const error = new Error("renderer reloaded");
              error.code = "WEBSOCKET_CLOSED";
              throw error;
            },
            close: () => { closes += 1; },
          };
        }
        return {
          call: async (method) => method === "Page.addScriptToEvaluateOnNewDocument"
            ? { identifier: "persistent-script" }
            : {},
          close: () => { closes += 1; },
        };
      },
      evaluate: async (_client, expression) => expression.includes("__CODEX_STATSIG_GATE_BRIDGE__")
        ? report
        : { targetGate: "782640499", remoteConnectionsGate: "4114442250" },
    },
  );
  assert.equal(connections, 2);
  assert.equal(closes, 2);
  assert.equal(result.renderer.currentDocument.installed, true);
  assert.equal(result.renderer.newDocumentScriptInstalled, true);
  assert.equal(result.renderer.probe.proof, true);
}

Promise.all([testOrchestratorProbeValidation(), testRendererInstallRetriesTransientReload()])
  .then(() => process.stdout.write(`${JSON.stringify({ ok: true, report })}\n`))
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
