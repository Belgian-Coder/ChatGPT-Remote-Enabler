"use strict";

const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { UpdateSessionController } = require("../update-session.js");
const {
  BINDING_NAME,
  CdpTransport,
  TARGET_URL,
  bootstrapSource,
  callbackSource,
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
    this.deletedOwnedBindings = 0;
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
    if (expression.includes("=== undefined;") && expression.includes(BINDING_NAME)) {
      return { result: { value: this.options.bindingAvailable !== false } };
    }
    if (expression.includes("Object.defineProperty(binding, property")) {
      return { result: { value: this.options.bindingClaimed !== false } };
    }
    if (expression.includes("Reflect.deleteProperty(globalThis") && expression.includes('binding["__chatgptRemoteUpdateOwnerV1"]')) {
      this.deletedOwnedBindings += 1;
      return { result: { value: this.options.deleteOwnedBinding !== false } };
    }
    if (expression.includes("typeof api?.getStatus")) {
      if (this.options.healthError) throw this.options.healthError;
      return { result: { value: this.options.healthProof !== false } };
    }
    if (expression.includes("updateActivity")) {
      if (this.activity) return { result: { value: await this.activity.promise } };
      return { result: { value: { known: true, busy: false, reason: null } } };
    }
    if (expression.includes("const internal = globalThis") && expression.includes('["setStatus"]')) {
      if (this.options.failStatusEvaluations > 0) {
        this.options.failStatusEvaluations -= 1;
        throw protocolError("Cannot find context with specified id");
      }
      return { result: { value: true } };
    }
    if (expression.includes("const internal = globalThis")
      && (expression.includes('["receive"]') || expression.includes('["dispose"]'))) {
      return { result: { value: true } };
    }
    if (expression.startsWith("(() => {")) {
      return { result: { value: this.options.invalidProof ? { installed: false, topFrame: true } : { installed: true, topFrame: true } } };
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
  const originalApi = context[PUBLIC_NAME];
  const reconnectProof = vm.runInContext(bootstrapSource("fixture-nonce", {
    state: "available", version: "v3", message: "reconnected", canQueue: true,
  }), context);
  assert.deepEqual({ ...reconnectProof }, { installed: true, topFrame: true });
  assert.equal(context[PUBLIC_NAME], originalApi, "a same-session reconnect must reuse the renderer controller");
  assert.equal(context[PUBLIC_NAME].getStatus().version, "v3");
  assert.equal(context[INTERNAL_NAME].receive({
    nonce: "fixture-nonce", id: "fixture-request", ok: true,
    status: { state: "current", version: "v3", message: null, canQueue: false, canCancel: false },
  }), true);
  assert.equal((await pending).version, "v3", "a pending request must survive a same-session reconnect");
  const pendingAfterReconnect = context[PUBLIC_NAME].request("queue");
  assert.equal(context[INTERNAL_NAME].dispose("fixture stopped"), true);
  await assert.rejects(pendingAfterReconnect, /fixture stopped/u);
  assert.equal(context[PUBLIC_NAME], undefined);
  assert.equal(context[INTERNAL_NAME], undefined);

  const scoped = makeBootstrapContext();
  delete scoped.context[BINDING_NAME];
  const firstBinding = `${BINDING_NAME}_first`;
  const secondBinding = `${BINDING_NAME}_second`;
  const firstRequests = [];
  const secondRequests = [];
  scoped.context[firstBinding] = (payload) => firstRequests.push(JSON.parse(payload));
  scoped.context[firstBinding].__chatgptRemoteUpdateOwnerV1 = "owner-first";
  const firstScopedProof = vm.runInContext(bootstrapSource("shared-nonce", status, firstBinding, "owner-first"), scoped.context);
  assert.deepEqual({ ...firstScopedProof }, { installed: true, topFrame: true });
  const firstScopedApi = scoped.context[PUBLIC_NAME];
  const firstScopedInternal = scoped.context[INTERNAL_NAME];
  const replacedPending = firstScopedApi.request("queue");
  scoped.context[secondBinding] = (payload) => secondRequests.push(JSON.parse(payload));
  scoped.context[secondBinding].__chatgptRemoteUpdateOwnerV1 = "owner-second";
  const secondScopedProof = vm.runInContext(bootstrapSource("shared-nonce", status, secondBinding, "owner-second"), scoped.context);
  assert.deepEqual({ ...secondScopedProof }, { installed: true, topFrame: true });
  await assert.rejects(replacedPending, /replaced/u);
  assert.notEqual(scoped.context[PUBLIC_NAME], firstScopedApi, "same-nonce reconnect reused an API bound to the predecessor attachment");
  assert.equal(vm.runInContext(callbackSource("shared-nonce", firstBinding, "owner-first", "setStatus", {
    state: "error", version: "v-old", message: "stale", canQueue: false, canCancel: false,
  }), scoped.context), false, "a predecessor callback reached the replacement API");
  assert.equal(scoped.context[PUBLIC_NAME].getStatus().version, "v2");
  assert.equal(vm.runInContext(callbackSource("shared-nonce", secondBinding, "owner-second", "setStatus", {
    state: "available", version: "v4", message: "current", canQueue: true, canCancel: false,
  }), scoped.context), true, "the current attachment callback was rejected");
  assert.equal(scoped.context[PUBLIC_NAME].getStatus().version, "v4");
  const newRequest = scoped.context[PUBLIC_NAME].request("check");
  assert.equal(firstRequests.length, 1, "replacement API sent another request through the predecessor binding");
  assert.deepEqual(secondRequests, [{ nonce: "shared-nonce", id: "fixture-request", action: "check" }]);
  assert.equal(firstScopedInternal.dispose("stale cleanup"), true);
  assert.ok(scoped.context[PUBLIC_NAME], "stale attachment cleanup removed the replacement API");
  scoped.context[INTERNAL_NAME].receive({
    nonce: "shared-nonce", id: "fixture-request", ok: true,
    status: { state: "current", version: "v3", message: null, canQueue: false, canCancel: false },
  });
  assert.equal((await newRequest).state, "current");

  const reloaded = makeBootstrapContext();
  delete reloaded.context[BINDING_NAME];
  const reloadBinding = `${BINDING_NAME}_reload`;
  const reloadRequests = [];
  reloaded.context[reloadBinding] = (payload) => reloadRequests.push(JSON.parse(payload));
  assert.equal(
    reloaded.context[reloadBinding].__chatgptRemoteUpdateOwnerV1,
    undefined,
    "reload fixture must model Runtime.addBinding's new unmarked function",
  );
  const reloadProof = vm.runInContext(
    bootstrapSource("reload-nonce", status, reloadBinding, "reload-owner"),
    reloaded.context,
  );
  assert.deepEqual({ ...reloadProof }, { installed: true, topFrame: true });
  assert.equal(
    reloaded.context[reloadBinding].__chatgptRemoteUpdateOwnerV1,
    "reload-owner",
    "new-document bootstrap did not reclaim its scoped Runtime binding",
  );
  const reloadRequest = reloaded.context[PUBLIC_NAME].request("check");
  assert.deepEqual(reloadRequests, [{ nonce: "reload-nonce", id: "fixture-request", action: "check" }]);
  reloaded.context[INTERNAL_NAME].receive({
    nonce: "reload-nonce", id: "fixture-request", ok: true,
    status: { state: "current", version: "v3", message: null, canQueue: false, canCancel: false },
  });
  assert.equal((await reloadRequest).state, "current");

  const foreignReload = makeBootstrapContext();
  delete foreignReload.context[BINDING_NAME];
  foreignReload.context[reloadBinding] = () => {};
  foreignReload.context[reloadBinding].__chatgptRemoteUpdateOwnerV1 = "foreign-owner";
  assert.deepEqual(
    { ...vm.runInContext(bootstrapSource("reload-nonce", status, reloadBinding, "reload-owner"), foreignReload.context) },
    { installed: false, topFrame: true },
    "new-document bootstrap claimed a binding already owned by another attachment",
  );
  assert.equal(foreignReload.context[PUBLIC_NAME], undefined);

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
  const firstBindingName = transport.session.bindingName;
  assert.notEqual(firstBindingName, BINDING_NAME, "renderer attachment reused the legacy global binding name");
  await transport.publish({ state: "available", version: "v3", message: "ready", canQueue: true });
  assert.equal((await transport.probeHealth()), true);
  assert.equal(transport.getHealth().connected, true);
  assert.ok(Number.isSafeInteger(transport.getHealth().rendererProofAtUnixMs));

  const payload = JSON.stringify({ nonce: "fixture-nonce", id: "request-1", action: "queue" });
  first.emit("Runtime.bindingCalled", { name: firstBindingName, executionContextId: 12, payload });
  first.emit("Runtime.bindingCalled", { name: firstBindingName, executionContextId: 11, payload: JSON.stringify({ nonce: "fixture-nonce", id: "bad-extra", action: "queue", extra: true }) });
  first.emit("Runtime.bindingCalled", { name: firstBindingName, executionContextId: 11, payload });
  first.emit("Runtime.bindingCalled", { name: firstBindingName, executionContextId: 11, payload });
  await waitFor(() => handled.length === 1, "The exact main-frame request was not handled.");
  handlerGate.resolve();
  await waitFor(
    () => first.calls.some((call) => call.method === "Runtime.evaluate" && call.params.expression.includes('["receive"]')),
    "The renderer request did not receive a reply.",
  );
  assert.deepEqual(handled, [{ action: "queue", id: "request-1" }]);
  const receive = first.calls.find((call) => call.method === "Runtime.evaluate" && call.params.expression.includes('["receive"]'));
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
    () => first.calls.some((call) => call.method === "Runtime.evaluate" && call.params.contextId === 21 && call.params.expression.includes('["setStatus"]')),
    "The last status did not converge after a reload context gap.",
  );

  first.emit("Page.frameNavigated", { frame: { id: "main-frame", url: "https://example.invalid/" } });
  first.emit("Runtime.executionContextCreated", {
    context: { id: 22, auxData: { isDefault: true, frameId: "main-frame" } },
  });
  first.emit("Runtime.bindingCalled", { name: firstBindingName, executionContextId: 22, payload: JSON.stringify({ nonce: "fixture-nonce", id: "wrong-url", action: "check" }) });
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(handled.length, 1, "A non-exact top-frame URL reached the request handler.");

  first.disconnect();
  await waitFor(() => cdp.connected.length === 3, "Transient context loss did not retry reattachment.");
  await waitFor(
    () => third.calls.some((call) => call.method === "Runtime.evaluate" && call.params.expression.includes('["setStatus"]')),
    "Reattachment did not restore the last status.",
  );
  assert.notEqual(transport.session.bindingName, firstBindingName, "reattachment reused a stale renderer binding name");
  assert.ok([first, second].some((client) => client.calls.some(
    (call) => call.method === "Page.removeScriptToEvaluateOnNewDocument" && call.params.identifier === "first-persistent",
  )), "reattachment did not remove the predecessor persistent bootstrap");
  assert.equal(second.closed, true);
  await transport.close();
  assert.equal(third.closed, true);
  assert.equal(transport.persistentIdentifier, null);
  assert.ok(third.calls.some((call) => call.method === "Runtime.removeBinding"));
  assert.ok(third.deletedOwnedBindings > 0, "close did not explicitly delete the owned renderer binding global");
}

async function healthRecoveryContract() {
  const first = new FakeClient("health-first", { healthProof: false });
  const terminalFailure = new FakeClient("health-terminal", { invalidProof: true });
  const recovered = new FakeClient("health-recovered");
  const cdp = new FakeCdp([first, terminalFailure, recovered]);
  const transport = new CdpTransport({ rendererPort: 1 }, "health-nonce", cdp, {
    timeoutMs: 100,
    healthIntervalMs: 10,
    reattachInitialDelayMs: 5,
    reattachMaximumDelayMs: 10,
  });
  await transport.attach();
  await waitFor(() => cdp.connected.length === 3 && transport.getHealth().connected, "The watchdog did not recover beyond a terminal attach failure.");
  assert.notEqual(transport.session.bindingName, BINDING_NAME);
  assert.equal(await transport.probeHealth(), true);
  assert.ok(terminalFailure.deletedOwnedBindings > 0, "failed attachment left its owned binding global behind");
  await transport.close();

  const occupied = new FakeClient("occupied", { bindingAvailable: false });
  const occupiedTransport = new CdpTransport({ rendererPort: 1 }, "occupied-nonce", new FakeCdp([occupied]), { timeoutMs: 100 });
  await assert.rejects(occupiedTransport.attach(), (error) => error?.code === "BINDING_BUSY");
  assert.equal(occupied.calls.some((call) => call.method === "Runtime.addBinding"), false, "foreign binding was overwritten");

  const stoppingClient = new FakeClient("stopping", { healthProof: false });
  const stoppingCdp = new FakeCdp([stoppingClient]);
  const stoppingTransport = new CdpTransport({ rendererPort: 1 }, "stopping-nonce", stoppingCdp, {
    timeoutMs: 100,
    healthIntervalMs: 10,
    reattachInitialDelayMs: 5,
    reattachMaximumDelayMs: 10,
  });
  await stoppingTransport.attach();
  assert.equal(await stoppingTransport.probeHealth(), false);
  await waitFor(() => stoppingCdp.discoveryCalls > 1, "The failed health probe did not begin autonomous retry.");
  await stoppingTransport.close();
  const stoppedDiscoveryCount = stoppingCdp.discoveryCalls;
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(stoppingCdp.discoveryCalls, stoppedDiscoveryCount, "close did not stop autonomous retries");
  assert.deepEqual(stoppingTransport.getHealth(), { connected: false, rendererProofAtUnixMs: null });
  assert.equal(stoppingTransport.healthTimer, null, "close left the health watchdog active");
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

  for (const protocolCode of [undefined, -32000, "-32000"]) {
    const old = new FakeClient("old-target", { invalidProof: true, removePersistentError: denied });
    const replacement = new FakeClient("replacement-target", {
      removePersistentError: Object.assign(new Error("Script not found"), { code: "CDP_PROTOCOL_ERROR", protocolCode }),
    });
    const reconnect = new CdpTransport({ rendererPort: 1 }, "fixture-nonce", new FakeCdp([old, replacement]), { timeoutMs: 250 });
    await assert.rejects(reconnect.attach(), (error) => error.code === "BOOTSTRAP_FAILED");
    assert.equal(reconnect.persistentIdentifier, "old-target-persistent");
    await reconnect.attach();
    assert.equal(reconnect.persistentIdentifier, "replacement-target-persistent", "a stale identifier from the old target must not prevent reconnection");
    await reconnect.close();
    assert.equal(reconnect.persistentIdentifier, null);
  }

}

async function reconnectInstalledVersionContract() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remote-update-reconnect-version-"));
  const first = new FakeClient("version-first");
  const second = new FakeClient("version-second");
  const third = new FakeClient("version-unknown");
  const transport = new CdpTransport({ rendererPort: 1 }, "version-nonce", new FakeCdp([first, second, third]), { timeoutMs: 250 });
  try {
    fs.writeFileSync(path.join(directory, "VERSION"), "v1.0.0\n");
    const controller = new UpdateSessionController({ installRoot: directory, stateRoot: path.join(directory, "state"), sessionDirectory: path.join(directory, "state", "sessions", "fixture") }, { transport, updater: {}, platform: {} });
    await controller.setStatus({ state: "current", version: "v1.0.0" }, false);
    fs.writeFileSync(path.join(directory, "VERSION"), "v1.5.99\n");
    first.disconnect();
    await waitFor(() => transport.client === second, "Renderer did not reconnect after external install.");
    assert.equal(transport.lastStatus.details.installedVersion, "v1.5.99");
    assert.equal(transport.lastStatus.version, "v1.5.99");
    const bootstrap = second.calls.find(call => call.method === "Page.addScriptToEvaluateOnNewDocument");
    assert.ok(bootstrap.params.source.includes('"installedVersion":"v1.5.99"'), "reconnect bootstrap must contain fresh disk version before any user action");
    fs.unlinkSync(path.join(directory, "VERSION"));
    second.disconnect();
    await waitFor(() => transport.client === third, "Renderer did not reconnect while disk version was unknown.");
    assert.equal(transport.lastStatus.details.installedVersion, null);
    assert.equal(transport.lastStatus.version, null);
    assert.equal(transport.lastStatus.state, "unavailable");
  } finally {
    await transport.close();
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

async function main() {
  await bootstrapContract();
  await exactTargetContract();
  await lifecycleContract();
  await healthRecoveryContract();
  await retainedCleanupContract();
  await reconnectInstalledVersionContract();
  console.log(JSON.stringify({
    bootstrapTimeoutAndDispose: true,
    exactTargetAndContext: true,
    reloadConvergence: true,
    reconnect: true,
    autonomousHealthRecovery: true,
    ownedScopedBindings: true,
    activityCoalesced: true,
    retainedCleanup: true,
  }));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
