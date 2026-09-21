"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");
const injector = require("../inject.js");

function testActionSpecificTargetWait() {
  assert.equal(injector.rendererTargetWaitMilliseconds("enable", 0), 30000,
    "cold enable must retain the full renderer replacement window without launcher assistance");
  assert.equal(injector.rendererTargetWaitMilliseconds("enable", 5000), 30000,
    "an older launcher wait must not shorten cold enable discovery");
  assert.equal(injector.rendererTargetWaitMilliseconds("probe", 0), 5000,
    "ordinary probes must retain the short target lookup");
  assert.equal(injector.rendererTargetWaitMilliseconds("probe", 30000), 30000,
    "an explicit longer lookup must still be honored");
}

async function testTransientDiscoveryRetry() {
  let attempts = 0;
  const target = { type: "page", url: "app://-/index.html", webSocketDebuggerUrl: "ws://127.0.0.1/fake" };
  const result = await injector.discoverRendererTarget(41001, 1000, {
    delay: async () => {},
    discoverTargets: async () => {
      attempts += 1;
      if (attempts < 3) {
        const error = new Error("not listening yet");
        error.code = "ECONNREFUSED";
        throw error;
      }
      return [target];
    },
  });
  assert.equal(result, target);
  assert.equal(attempts, 3);
  assert.throws(() => injector.exactRendererTarget([target, { ...target, type: "webview" }]), (error) => error?.code === "TARGET_AMBIGUOUS");
}

async function testTransientConnectRetry() {
  let discoveries = 0;
  let connections = 0;
  const client = { close() {} };
  const result = await injector.connectRendererTargetWithRetry(41001, 1000, {
    delay: async () => {},
    discoverTargets: async () => {
      discoveries += 1;
      return [{ type: "page", url: "app://-/index.html", webSocketDebuggerUrl: `ws://127.0.0.1/${discoveries}` }];
    },
    connectTarget: async (target) => {
      connections += 1;
      if (connections === 1) {
        const error = new Error("renderer target was replaced");
        error.code = "WEBSOCKET_CONNECT_FAILED";
        throw error;
      }
      assert.equal(target.webSocketDebuggerUrl, "ws://127.0.0.1/2");
      return client;
    },
  });
  assert.equal(result, client);
  assert.equal(discoveries, 2);
  assert.equal(connections, 2);

  let targetSlices = 0;
  const lateTargetClient = { close() {} };
  const lateTargetResult = await injector.connectRendererTargetWithRetry(41001, 1000, {
    delay: async () => {},
    discoverRendererTarget: async () => {
      targetSlices += 1;
      if (targetSlices === 1) {
        const error = new Error("exact target is still loading");
        error.code = "TARGET_NOT_FOUND";
        throw error;
      }
      return { type: "page", url: "app://-/index.html", webSocketDebuggerUrl: "ws://127.0.0.1/late" };
    },
    connectTarget: async () => lateTargetClient,
  });
  assert.equal(lateTargetResult, lateTargetClient);
  assert.equal(targetSlices, 2);

  const terminal = new Error("ambiguous target");
  terminal.code = "TARGET_AMBIGUOUS";
  let terminalAttempts = 0;
  await assert.rejects(
    injector.connectRendererTargetWithRetry(41001, 1000, {
      discoverTargets: async () => { terminalAttempts += 1; throw terminal; },
    }),
    (error) => error === terminal,
  );
  assert.equal(terminalAttempts, 1);

  const exhausted = new Error("renderer stayed unavailable");
  exhausted.code = "WEBSOCKET_CONNECT_FAILED";
  await assert.rejects(
    injector.connectRendererTargetWithRetry(41001, 1, {
      delay: async () => {},
      discoverTargets: async () => [{ type: "page", url: "app://-/index.html", webSocketDebuggerUrl: "ws://127.0.0.1/stale" }],
      connectTarget: async () => { throw exhausted; },
    }),
    (error) => error === exhausted,
  );

  const finalSlice = new Error("Exact Codex renderer target was not found after 1 ms");
  finalSlice.code = "TARGET_NOT_FOUND";
  await assert.rejects(
    injector.connectRendererTargetWithRetry(41001, 20, {
      delay: async () => new Promise((resolve) => setTimeout(resolve, 25)),
      discoverRendererTarget: async () => { throw finalSlice; },
    }),
    (error) => error?.code === "TARGET_NOT_FOUND"
      && error.message === "Exact Codex renderer target was not found after 20 ms"
      && error.cause === finalSlice,
  );
}

async function testPersistentCleanupRetention() {
  const registrations = [
    { identifier: "remove-me", port: 41001 },
    { identifier: "retain-failed", port: 41001 },
    { identifier: "other-port", port: 41002 },
  ];
  const calls = [];
  const result = await injector.removeRegistrations({
    call: async (_method, { identifier }) => {
      calls.push(identifier);
      if (identifier === "retain-failed") {
        const error = new Error("socket closed");
        error.code = "WEBSOCKET_CLOSED";
        throw error;
      }
    },
  }, registrations, 41001, {
    discoverTargets: async () => [{ type: "page", url: "app://-/index.html", webSocketDebuggerUrl: "ws://127.0.0.1/fake" }],
  });
  assert.deepEqual(calls, ["remove-me", "retain-failed"]);
  assert.deepEqual(result.pending.map((item) => item.identifier), ["retain-failed", "other-port"]);
  assert.equal(result.failures.length, 1);
  assert.deepEqual(result.stale, []);
}

async function testDisablePrunesDeadRegistrations() {
  let persisted = [
    { identifier: "current", port: 41001 },
    { identifier: "dead-ephemeral", port: 41002 },
  ];
  const calls = [];
  const result = await injector.disableRenderer({
    call: async (_method, { identifier }) => { calls.push(identifier); },
  }, 41001, {
    evaluate: async () => ({ active: false, version: null }),
    readSessionState: () => persisted,
    persistSessionState: (registrations) => { persisted = registrations; },
    discoverTargets: async (port) => {
      assert.equal(port, 41002);
      const error = new Error("old renderer port is closed");
      error.code = "ECONNREFUSED";
      throw error;
    },
  });
  assert.deepEqual(calls, ["current"]);
  assert.deepEqual(persisted, [], "dead old registrations must be pruned from durable state");
  assert.deepEqual(result.stale, [{ identifier: "dead-ephemeral", port: 41002 }]);
  assert.deepEqual(result.report, { active: false, version: null });
}

function testAtomicStateAndLegacyMigration() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codex-mobile-injector-test-"));
  const statePath = path.join(root, "state", "session.json");
  const legacyPath = path.join(root, "legacy.json");
  try {
    fs.writeFileSync(legacyPath, `${JSON.stringify({ identifier: "legacy", port: 41001, version: 1 })}\n`);
    const registrations = injector.readSessionState([statePath, legacyPath]);
    assert.deepEqual(registrations, [{ identifier: "legacy", port: 41001, version: 1 }]);
    injector.persistSessionState([
      ...registrations,
      { identifier: "current", port: 41002, version: 2 },
    ], statePath, legacyPath);
    const stored = JSON.parse(fs.readFileSync(statePath, "utf8"));
    assert.equal(stored.schemaVersion, 2);
    assert.deepEqual(stored.registrations.map((item) => item.identifier), ["legacy", "current"]);
    assert.equal(fs.existsSync(legacyPath), false);
    injector.persistSessionState([{ identifier: "replacement", port: 41003, version: 3 }], statePath, legacyPath);
    assert.deepEqual(JSON.parse(fs.readFileSync(statePath, "utf8")).registrations, [
      { identifier: "replacement", port: 41003, version: 3 },
    ]);
    assert.deepEqual(fs.readdirSync(path.dirname(statePath)), ["session.json"]);
  } finally {
    fs.rmSync(root, { force: true, recursive: true });
  }
}

function testInactiveMutationFails() {
  assert.throws(() => injector.assertActiveReport({ active: false, version: null }, "auto-on"), /inactive/u);
  const expression = injector.requiredApiCall(["setAutoRegistration"], [true]);
  assert.throws(() => vm.runInNewContext(expression, {}), /command is unavailable/u);
  const context = {
    __CODEX_REMOTE_MOBILE_PROJECT_VIEW__: {
      probe: () => ({ active: true, version: 1 }),
      setAutoRegistration: (enabled) => ({ active: true, enabled, version: 1 }),
    },
  };
  assert.deepEqual(vm.runInNewContext(expression, context), { active: true, enabled: true, version: 1 });
}

async function main() {
  testActionSpecificTargetWait();
  await testTransientDiscoveryRetry();
  await testTransientConnectRetry();
  await testPersistentCleanupRetention();
  await testDisablePrunesDeadRegistrations();
  testAtomicStateAndLegacyMigration();
  testInactiveMutationFails();
  process.stdout.write(`${JSON.stringify({ actionSpecificTargetWait: true, atomicState: true, cleanupRetention: true, disablePrunesDeadRegistrations: true, inactiveMutationFails: true, transientDiscoveryRetry: true, transientConnectRetry: true })}\n`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
