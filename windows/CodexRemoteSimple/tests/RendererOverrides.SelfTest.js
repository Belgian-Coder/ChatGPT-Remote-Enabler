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
  const { runProbeBridge } = require("../runtime/orchestrator.js");
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
}

testOrchestratorProbeValidation()
  .then(() => process.stdout.write(`${JSON.stringify({ ok: true, report })}\n`))
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
