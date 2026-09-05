"use strict";

const assert = require("node:assert/strict");
const vm = require("node:vm");
const {
  BINDING_NAME,
  CdpTransport,
  TARGET_URL,
  bootstrapSource,
} = require("../update-session-cdp.js");

const INTERNAL_NAME = "__CHATGPT_REMOTE_UPDATE_INTERNAL__";
const PUBLIC_NAME = "__CHATGPT_REMOTE_UPDATE__";

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

async function waitFor(predicate, message, timeoutMs = 2_000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(message);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

function protocolError(message, protocolCode = -32000) {
  const error = new Error(`Debugger protocol error ${protocolCode} in fixture: ${message}`);
  error.code = "CDP_PROTOCOL_ERROR";
  error.protocolCode = protocolCode;
  return error;
}

class FakeClient {
  constructor(name, options = {}) {
    this.name = name;
    this.options = options;
    this.calls = [];
    this.closeHandlers = new Set();
    this.eventHandlers = new Set();
    this.closed = false;
    this.activity = null;
    this.identifier = options.identifier ?? `${name}-persistent`;
  }

  onEvent(handler) {
    this.eventHandlers.add(handler);
    return () => this.eventHandlers.delete(handler);
  }

  onClose(handler) {
    this.closeHandlers.add(handler);
    return () => this.closeHandlers.delete(handler);
  }

  emit(method, params = {}) {
    for (const handler of [...this.eventHandlers]) handler(method, params);
  }

  disconnect() {
    for (const handler of [...this.closeHandlers]) handler(new Error("fixture disconnect"));
  }

  close() {
    this.closed = true;
    this.disconnect();
  }

  async call(method, params, timeoutMs) {
    this.calls.push({ method, params, timeoutMs });
    if (method === "Page.enable") return {};
    if (method === "Page.getFrameTree") {
      return { frameTree: { frame: { id: "main-frame", url: this.options.frameUrl ?? TARGET_URL } } };
    }
    if (method === "Runtime.enable") {
      this.emit("Runtime.executionContextCreated", {
        context: { id: 12, auxData: { isDefault: true, frameId: "child-frame" } },
      });
      this.emit("Runtime.executionContextCreated", {
        context: { id: 11, auxData: { isDefault: true, frameId: "main-frame" } },
      });
      return {};
    }
    if (method === "Runtime.removeBinding" || method === "Runtime.addBinding") return {};
    if (method === "Page.addScriptToEvaluateOnNewDocument") {
      return this.options.invalidPersistent ? {} : { identifier: this.identifier };
    }
    if (method === "Page.removeScriptToEvaluateOnNewDocument") {
      if (this.options.removePersistentError) throw this.options.removePersistentError;
      return {};
    }
    if (method !== "Runtime.evaluate") throw new Error(`Unexpected fake CDP call: ${method}`);

    const expression = params.expression;
    if (expression.startsWith("(() => {")) {
      return { result: { value: this.options.invalidProof ? { installed: false, topFrame: true } : { installed: true, topFrame: true } } };
    }
    if (expression.includes("updateActivity")) {
      if (this.activity) return { result: { value: await this.activity.promise } };
      return { result: { value: { known: true, busy: false, reason: null } } };
    }
    if (expression.includes("?.[\"setStatus\"]?.")) {
      if (this.options.failStatusEvaluations > 0) {
        this.options.failStatusEvaluations -= 1;
        throw protocolError("Cannot find context with specified id");
      }
      return { result: { value: true } };
    }
    if (expression.includes("?.[\"receive\"]?.") || expression.includes("?.[\"dispose\"]?.")) {
      return { result: { value: true } };
    }
    throw new Error(`Unexpected fake evaluation: ${expression}`);
  }
}

class FakeCdp {
  constructor(clients, targets = null) {
    this.clients = [...clients];
    this.connected = [];
    this.discoveryCalls = 0;
    this.targets = targets ?? [{ type: "page", url: TARGET_URL, webSocketDebuggerUrl: "ws://fixture/devtools/page/main" }];
  }

  async discoverTargets() {
    this.discoveryCalls += 1;
    return this.targets;
  }

  async connectTarget() {
    const client = this.clients.shift();
    if (!client) throw new Error("No fake CDP client remains.");
    this.connected.push(client);
    return client;
  }
}

function makeBootstrapContext(url = TARGET_URL, topFrame = true) {
  const requests = [];
  const context = {
    CustomEvent: class CustomEvent {
      constructor(type, options) { this.type = type; this.detail = options?.detail; }
    },
    clearTimeout,
    crypto: { randomUUID: () => "fixture-request" },
    document: { dispatchEvent() {} },
    location: { href: url },
    setTimeout,
  };
  context.globalThis = context;
  context.top = topFrame ? context : {};
  context[BINDING_NAME] = (payload) => requests.push(JSON.parse(payload));
  vm.createContext(context);
  return { context, requests };
}

async function bootstrapContract() {
  const status = { state: "available", version: "v2", message: "ready", canQueue: true, extra: "ignored" };
  const { context, requests } = makeBootstrapContext();
  const proof = vm.runInContext(bootstrapSource("fixture-nonce", status), context);
  assert.deepEqual({ ...proof }, { installed: true, topFrame: true });
  assert.equal(context[PUBLIC_NAME].getStatus().state, "available");
  assert.equal("extra" in context[PUBLIC_NAME].getStatus(), false);

  const reply = context[PUBLIC_NAME].request("check");
  assert.deepEqual(requests, [{ nonce: "fixture-nonce", id: "fixture-request", action: "check" }]);
  assert.equal(context[INTERNAL_NAME].receive({
    nonce: "fixture-nonce", id: "fixture-request", ok: true,
    status: { state: "current", version: "v2", message: null, canQueue: false, canCancel: false },
  }), true);
  assert.equal((await reply).state, "current");

  const pending = context[PUBLIC_NAME].request("queue");
  assert.equal(context[INTERNAL_NAME].dispose("fixture stopped"), true);
  await assert.rejects(pending, /fixture stopped/u);
  assert.equal(context[PUBLIC_NAME], undefined);
  assert.equal(context[INTERNAL_NAME], undefined);

  const wrongUrl = makeBootstrapContext("https://example.invalid/").context;
  assert.deepEqual(
    { ...vm.runInContext(bootstrapSource("fixture-nonce", status), wrongUrl) },
    { installed: false, topFrame: true },
  );
  assert.equal(wrongUrl[PUBLIC_NAME], undefined);
  const childFrame = makeBootstrapContext(TARGET_URL, false).context;
  assert.deepEqual(
    { ...vm.runInContext(bootstrapSource("fixture-nonce", status), childFrame) },
    { installed: false, topFrame: false },
  );
}

async function exactTargetContract() {
  const targets = [
    { type: "page", url: TARGET_URL, webSocketDebuggerUrl: "ws://fixture/one" },
    { type: "webview", url: TARGET_URL, webSocketDebuggerUrl: "ws://fixture/two" },
  ];
  const cdp = new FakeCdp([], targets);
  const transport = new CdpTransport({ rendererPort: 1 }, "nonce", cdp, { timeoutMs: 250 });
  await assert.rejects(transport.attach(), (error) => error.code === "TARGET_AMBIGUOUS");
  assert.equal(cdp.connected.length, 0);

  const wrongType = new FakeCdp([], [{ type: "worker", url: TARGET_URL, webSocketDebuggerUrl: "ws://fixture/worker" }]);
  await assert.rejects(
    new CdpTransport({ rendererPort: 1 }, "nonce", wrongType, { timeoutMs: 250 }).attach(),
    (error) => error.code === "TARGET_NOT_FOUND",
  );

  const invalidFrame = new FakeClient("invalid-frame", { frameUrl: "https://example.invalid/" });
  await assert.rejects(
    new CdpTransport({ rendererPort: 1 }, "nonce", new FakeCdp([invalidFrame]), { timeoutMs: 250 }).attach(),
    (error) => error.code === "TARGET_INVALID",
  );
  assert.equal(invalidFrame.closed, true);
}

async function lifecycleContract() {
  const first = new FakeClient("first");
  const second = new FakeClient("second", { failStatusEvaluations: 1 });
  const third = new FakeClient("third");
  const cdp = new FakeCdp([first, second, third]);
  const transport = new CdpTransport({ rendererPort: 1 }, "fixture-nonce", cdp, { timeoutMs: 250 });
  const handled = [];
  const handlerGate = deferred();
  transport.onRequest(async (action, id) => {
    handled.push({ action, id });
    await handlerGate.promise;
    return { state: "available", version: "v3", canQueue: true };
  });
  await transport.attach();
  await transport.publish({ state: "available", version: "v3", message: "ready", canQueue: true });

  const payload = JSON.stringify({ nonce: "fixture-nonce", id: "request-1", action: "queue" });
  first.emit("Runtime.bindingCalled", { name: BINDING_NAME, executionContextId: 12, payload });
  first.emit("Runtime.bindingCalled", { name: BINDING_NAME, executionContextId: 11, payload: JSON.stringify({ nonce: "fixture-nonce", id: "bad-extra", action: "queue", extra: true }) });
  first.emit("Runtime.bindingCalled", { name: BINDING_NAME, executionContextId: 11, payload });
  first.emit("Runtime.bindingCalled", { name: BINDING_NAME, executionContextId: 11, payload });
  await waitFor(() => handled.length === 1, "The exact main-frame request was not handled.");
  handlerGate.resolve();
  await waitFor(
    () => first.calls.some((call) => call.method === "Runtime.evaluate" && call.params.expression.includes("?.[\"receive\"]?.")),
    "The renderer request did not receive a reply.",
  );
  assert.deepEqual(handled, [{ action: "queue", id: "request-1" }]);
  const receive = first.calls.find((call) => call.method === "Runtime.evaluate" && call.params.expression.includes("?.[\"receive\"]?."));
  assert.equal(receive.params.contextId, 11);

  first.activity = deferred();
  const activityOne = transport.queryActivity();
  const activityTwo = transport.queryActivity();
  await waitFor(
    () => first.calls.filter((call) => call.method === "Runtime.evaluate" && call.params.expression.includes("updateActivity")).length === 1,
    "Activity queries were not coalesced.",
  );
  const activityCall = first.calls.find((call) => call.method === "Runtime.evaluate" && call.params.expression.includes("updateActivity"));
  assert.ok(activityCall.timeoutMs >= 35_000, "Activity evaluation must outlive the renderer's 30-second request timeout.");
  first.activity.resolve({ known: true, busy: true, reason: "fixture busy" });
  assert.deepEqual(await activityOne, { known: true, busy: true, reason: "fixture busy" });
  assert.deepEqual(await activityTwo, { known: true, busy: true, reason: "fixture busy" });

  first.emit("Page.frameNavigated", { frame: { id: "main-frame", url: TARGET_URL } });
  first.emit("Runtime.executionContextsCleared", {});
  await new Promise((resolve) => setTimeout(resolve, 10));
  first.emit("Runtime.executionContextCreated", {
    context: { id: 21, auxData: { isDefault: true, frameId: "main-frame" } },
  });
  await waitFor(
    () => first.calls.some((call) => call.method === "Runtime.evaluate" && call.params.contextId === 21 && call.params.expression.includes("?.[\"setStatus\"]?.")),
    "The last status did not converge after a reload context gap.",
  );

  first.emit("Page.frameNavigated", { frame: { id: "main-frame", url: "https://example.invalid/" } });
  first.emit("Runtime.executionContextCreated", {
    context: { id: 22, auxData: { isDefault: true, frameId: "main-frame" } },
  });
  first.emit("Runtime.bindingCalled", { name: BINDING_NAME, executionContextId: 22, payload: JSON.stringify({ nonce: "fixture-nonce", id: "wrong-url", action: "check" }) });
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(handled.length, 1, "A non-exact top-frame URL reached the request handler.");

  first.disconnect();
  await waitFor(() => cdp.connected.length === 3, "Transient context loss did not retry reattachment.");
  await waitFor(
    () => third.calls.some((call) => call.method === "Runtime.evaluate" && call.params.expression.includes("?.[\"setStatus\"]?.")),
    "Reattachment did not restore the last status.",
  );
  assert.ok(second.calls.some((call) => call.method === "Page.removeScriptToEvaluateOnNewDocument" && call.params.identifier === "first-persistent"));
  assert.equal(second.closed, true);
  await transport.close();
  assert.equal(third.closed, true);
  assert.equal(transport.persistentIdentifier, null);
  assert.ok(third.calls.some((call) => call.method === "Runtime.removeBinding"));
}

async function retainedCleanupContract() {
  const denied = protocolError("Access denied");
  const failed = new FakeClient("failed", { invalidProof: true, removePersistentError: denied });
  const recovered = new FakeClient("recovered");
  const cdp = new FakeCdp([failed, recovered]);
  const transport = new CdpTransport({ rendererPort: 1 }, "fixture-nonce", cdp, { timeoutMs: 250 });
  await assert.rejects(transport.attach(), (error) => error.code === "BOOTSTRAP_FAILED");
  assert.equal(transport.persistentIdentifier, "failed-persistent", "A failed persistent cleanup must remain retained.");
  assert.ok(failed.calls.some((call) => call.method === "Runtime.removeBinding"));

  await transport.attach();
  assert.ok(recovered.calls.some((call) => call.method === "Page.removeScriptToEvaluateOnNewDocument" && call.params.identifier === "failed-persistent"));
  assert.equal(transport.persistentIdentifier, "recovered-persistent");
  recovered.options.removePersistentError = protocolError("Access denied");
  await transport.close();
  assert.equal(transport.persistentIdentifier, "recovered-persistent", "Close must retain an identifier whose cleanup was not confirmed.");

  const missing = new FakeClient("already-missing", {
    removePersistentError: protocolError("Page.removeScriptToEvaluateOnNewDocument: Script not found"),
  });
  const missingTransport = new CdpTransport({ rendererPort: 1 }, "fixture-nonce", new FakeCdp([missing]), { timeoutMs: 250 });
  await missingTransport.attach();
  await missingTransport.close();
  assert.equal(missingTransport.persistentIdentifier, null, "Chromium's exact missing-script response is confirmed cleanup.");
}

async function main() {
  await bootstrapContract();
  await exactTargetContract();
  await lifecycleContract();
  await retainedCleanupContract();
  console.log(JSON.stringify({
    bootstrapTimeoutAndDispose: true,
    exactTargetAndContext: true,
    reloadConvergence: true,
    reconnect: true,
    activityCoalesced: true,
    retainedCleanup: true,
  }));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
