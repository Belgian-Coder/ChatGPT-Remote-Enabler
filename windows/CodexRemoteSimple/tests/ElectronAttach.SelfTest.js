"use strict";

const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const vm = require("node:vm");

const attach = require("../runtime/lib/electron-attach.js");

class FakeDebugger extends EventEmitter {
  constructor() {
    super();
    this.attached = false;
    this.attachCalls = 0;
    this.detachCalls = 0;
    this.commands = [];
    this.sessions = new Set();
    this.failTargetInfo = false;
  }

  attach() {
    this.attachCalls += 1;
    if (this.attached) throw Object.assign(new Error("already attached"), { code: "DEBUGGER_ALREADY_ATTACHED" });
    this.attached = true;
  }

  detach() {
    this.detachCalls += 1;
    this.attached = false;
  }

  isAttached() { return this.attached; }

  async sendCommand(method, params = {}, sessionId) {
    this.commands.push({ method, params, sessionId });
    if (method === "Target.getTargetInfo") {
      if (this.failTargetInfo) throw Object.assign(new Error("target info failed"), { code: "TARGET_INFO_FAILED" });
      return { targetInfo: { targetId: "target-42" } };
    }
    if (method === "Target.attachToTarget") {
      const value = `session-${this.sessions.size + 1}`;
      this.sessions.add(value);
      return { sessionId: value };
    }
    if (method === "Target.detachFromTarget") {
      this.sessions.delete(params.sessionId);
      return {};
    }
    return { echoed: true, method, params, sessionId };
  }
}

class FakeWebContents extends EventEmitter {
  constructor(id, url, debuggerApi) {
    super();
    this.id = id;
    this.url = url;
    this.debugger = debuggerApi;
    this.destroyed = false;
  }

  getURL() { return this.url; }
  isDestroyed() { return this.destroyed; }
}

class FakeMainClient {
  constructor(context) {
    this.context = context;
    this.events = new Set();
    this.closes = new Set();
    this.connected = false;
    this.closed = false;
    this.bindings = new Set();
    this.failNextEvaluation = null;
  }

  async connect() {
    this.connected = true;
    return this;
  }

  onEvent(handler) {
    this.events.add(handler);
    return () => this.events.delete(handler);
  }

  onClose(handler) {
    this.closes.add(handler);
    return () => this.closes.delete(handler);
  }

  async call(method, params = {}) {
    if (method === "Runtime.enable") return {};
    if (method === "Runtime.addBinding") {
      this.bindings.add(params.name);
      this.context.globalThis[params.name] = (payload) => {
        for (const handler of this.events) {
          handler("Runtime.bindingCalled", { name: params.name, payload });
        }
      };
      return {};
    }
    if (method === "Runtime.removeBinding") {
      this.bindings.delete(params.name);
      return {};
    }
    if (method !== "Runtime.evaluate") throw new Error(`unexpected main call ${method}`);
    if (this.failNextEvaluation) {
      const error = this.failNextEvaluation;
      this.failNextEvaluation = null;
      throw error;
    }
    const value = await vm.runInContext(params.expression, this.context);
    return { result: { value } };
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    for (const handler of this.closes) handler(Object.assign(new Error("closed"), { code: "WEBSOCKET_CLOSED" }));
  }

  emitProtocol(method, params, sessionId) {
    const debuggerApi = this.context.__debugger;
    debuggerApi.emit("message", {}, method, params, sessionId);
  }
}

function makeFixture() {
  const debuggerApi = new FakeDebugger();
  const webContents = new FakeWebContents(7, attach.ELECTRON_TARGET_URL, debuggerApi);
  const electron = {
    webContents: {
      fromId(id) { return id === webContents.id ? webContents : null; },
      getAllWebContents() { return [webContents]; },
    },
  };
  const processFixture = {
    pid: 7311,
    type: "browser",
    execPath: "C:\\Program Files\\ChatGPT\\ChatGPT.exe",
    resourcesPath: "C:\\Program Files\\ChatGPT\\resources",
    getBuiltinModule(name) {
      assert.equal(name, "module");
      return { createRequire() { return () => electron; } };
    },
  };
  const context = vm.createContext({
    process: processFixture,
    Date,
    Map,
    Promise,
    Symbol,
    JSON,
    Error,
    Object,
    String,
    Number,
    Math,
    setInterval,
    clearInterval,
    console,
    __debugger: debuggerApi,
  });
  context.globalThis = context;
  const mainClients = [];
  const createMainClient = () => {
    const client = new FakeMainClient(context);
    mainClients.push(client);
    return client;
  };
  const target = {
    _codexElectronAttachTarget: attach.ELECTRON_ATTACH_TARGET_MARKER,
    webContentsId: webContents.id,
    expectedPid: processFixture.pid,
    expectedUrl: attach.ELECTRON_TARGET_URL,
    mainWebSocketDebuggerUrl: "ws://127.0.0.1:4567/inspector",
  };
  return { context, debuggerApi, electron, processFixture, webContents, mainClients, createMainClient, target };
}

function dependencies(fixture) {
  return {
    createMainClient: fixture.createMainClient,
    forceLoopbackWebSocketUrl: (url) => url,
  };
}

async function connect(fixture, target = fixture.target) {
  return attach.connectElectronTarget(target, 4567, 1_000, dependencies(fixture));
}

async function closeClient(client) {
  client.close();
  await client.cleanupPromise;
}

function assertNoOwnedBindings(fixture, message) {
  const names = Object.keys(fixture.context).filter((name) => name.startsWith("__codexElectronAttach_"));
  assert.deepEqual(names, [], message);
}

async function testDiscoveryEvaluator() {
  const fixture = makeFixture();
  fixture.webContents.url = "app://-/index.html";
  const result = JSON.parse(JSON.stringify(await vm.runInContext(attach.buildDiscoveryExpression(), fixture.context)));
  assert.deepEqual(result, { ok: true, pid: fixture.processFixture.pid, targets: [{ id: 7, url: "app://-/index.html" }] });
  fixture.webContents.url = "app://-/other.html";
  const filtered = JSON.parse(JSON.stringify(await vm.runInContext(attach.buildDiscoveryExpression(), fixture.context)));
  assert.deepEqual(filtered.targets, []);
}

async function testIndependentSessionsAndEvents() {
  const fixture = makeFixture();
  const foreignGlobal = () => "foreign";
  fixture.context.globalThis.foreignGlobal = foreignGlobal;
  const [first, second] = await Promise.all([connect(fixture), connect(fixture)]);
  assert.equal(fixture.debuggerApi.attachCalls, 1, "webContents debugger root was attached more than once");
  assert.equal(fixture.debuggerApi.sessions.size, 2, "each client needs an independent flattened session");
  const firstEvents = [];
  const secondEvents = [];
  first.onEvent((method, params) => firstEvents.push({ method, params }));
  second.onEvent((method, params) => secondEvents.push({ method, params }));
  await first.call("Runtime.enable");
  await second.call("Runtime.enable");
  const sessionCalls = fixture.debuggerApi.commands.filter((entry) => entry.method === "Runtime.enable");
  assert.deepEqual(sessionCalls.map((entry) => entry.sessionId), [first.sessionId, second.sessionId]);
  fixture.debuggerApi.emit("message", {}, "Runtime.executionContextCreated", { context: { id: 1 } }, first.sessionId);
  fixture.debuggerApi.emit("message", {}, "Runtime.executionContextCreated", { context: { id: 2 } }, second.sessionId);
  assert.equal(firstEvents.length, 1);
  assert.equal(firstEvents[0].params.context.id, 1);
  assert.equal(secondEvents.length, 1);
  assert.equal(secondEvents[0].params.context.id, 2);
  const firstState = fixture.webContents[Symbol.for("codex.remote-enabler.electron-attach.state.v1")];
  assert.equal(firstState.refs, 2);
  await closeClient(first);
  assert.equal(fixture.debuggerApi.detachCalls, 0, "closing one client detached the shared root");
  assert.equal(firstState.refs, 1);
  assert.equal(fixture.context.globalThis[first.identity.bindingName], undefined, "closing one client left its binding global behind");
  assert.equal(typeof fixture.context.globalThis[second.identity.bindingName], "function", "closing one client removed another client's binding");
  await closeClient(second);
  assert.equal(fixture.debuggerApi.detachCalls, 1, "last client did not release the owned root");
  assert.equal(fixture.webContents[Symbol.for("codex.remote-enabler.electron-attach.state.v1")], undefined);
  assertNoOwnedBindings(fixture, "normal cleanup left owned binding globals behind");
  assert.equal(fixture.context.globalThis.foreignGlobal, foreignGlobal, "normal cleanup touched a foreign global");

  const repeated = await connect(fixture);
  const sameNameForeignGlobal = () => "same-name-foreign";
  fixture.context.globalThis[repeated.identity.bindingName] = sameNameForeignGlobal;
  await closeClient(repeated);
  assert.equal(fixture.context.globalThis[repeated.identity.bindingName], sameNameForeignGlobal, "cleanup deleted a foreign replacement global");
  assert.equal(fixture.debuggerApi.attachCalls, 2, "repeated connect did not establish a fresh owned root");
}

async function testIdentityAndForeignOwnership() {
  const wrongPid = makeFixture();
  await assert.rejects(connect(wrongPid, { ...wrongPid.target, expectedPid: wrongPid.processFixture.pid + 1 }), (error) => error?.code === "ELECTRON_PROCESS_CHANGED");
  assert.equal(wrongPid.debuggerApi.attachCalls, 0);

  const foreign = makeFixture();
  foreign.debuggerApi.attached = true;
  await assert.rejects(connect(foreign), (error) => error?.code === "ELECTRON_DEBUGGER_BUSY");
  assert.equal(foreign.debuggerApi.detachCalls, 0, "foreign debugger ownership was detached");

  const occupied = makeFixture();
  const occupiedClient = new attach.ElectronAttachClient({ ...occupied.target, port: 4567 }, {
    timeoutMs: 1_000,
    createMainClient: occupied.createMainClient,
    forceLoopbackWebSocketUrl: (url) => url,
  });
  const occupiedGlobal = () => "foreign";
  occupied.context.globalThis[occupiedClient.identity.bindingName] = occupiedGlobal;
  await assert.rejects(occupiedClient.connect(), (error) => error?.code === "ELECTRON_BINDING_BUSY");
  assert.equal(occupied.context.globalThis[occupiedClient.identity.bindingName], occupiedGlobal, "binding availability check touched a foreign global");
  assert.equal(occupied.debuggerApi.attachCalls, 0, "occupied binding attempted a renderer debugger attach");

  const changedUrl = makeFixture();
  changedUrl.webContents.url = "app://-/different.html";
  await assert.rejects(connect(changedUrl), (error) => error?.code === "ELECTRON_TARGET_CHANGED");

  const stale = makeFixture();
  const previous = await connect(stale);
  stale.debuggerApi.detach();
  const replacement = await connect(stale);
  assert.equal(stale.debuggerApi.attachCalls, 2, "a stale root was reused after the debugger detached");
  await closeClient(previous);
  await closeClient(replacement);
}

async function testLeaseAndDetachCleanup() {
  assert.equal(attach.ELECTRON_ATTACH_LEASE_HEARTBEAT_MS, 10_000);
  assert.equal(attach.ELECTRON_ATTACH_LEASE_EXPIRY_MS, 35_000);

  const failed = makeFixture();
  failed.debuggerApi.failTargetInfo = true;
  await assert.rejects(connect(failed), (error) => error?.code === "TARGET_INFO_FAILED");
  assert.equal(failed.debuggerApi.detachCalls, 1, "failed bootstrap left the owned debugger attached");
  assert.equal(failed.webContents[Symbol.for("codex.remote-enabler.electron-attach.state.v1")], undefined);
  assertNoOwnedBindings(failed, "bootstrap failure left an owned binding global behind");

  const leaseFixture = makeFixture();
  const leased = await connect(leaseFixture);
  const leaseState = leaseFixture.webContents[Symbol.for("codex.remote-enabler.electron-attach.state.v1")];
  leaseState.sessions.get(leased.identity.sessionToken).lastHeartbeat = Date.now() - 40_000;
  let leaseCloseError;
  leased.onClose((error) => { leaseCloseError = error; });
  leaseState.sweepLeases();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(leaseCloseError.code, "ELECTRON_DEBUGGER_DETACHED");
  assert.equal(leased.heartbeatTimer, null, "lease expiry left the client heartbeat active");
  assert.equal(leaseFixture.debuggerApi.detachCalls, 1, "lease expiry did not release the owned root");
  assert.equal(leaseFixture.context.globalThis[leased.identity.bindingName], undefined, "lease expiry left the binding global behind");
  await closeClient(leased);

  const fixture = makeFixture();
  const client = await connect(fixture);
  let closeError;
  client.onClose((error) => { closeError = error; });
  fixture.debuggerApi.emit("detach", {}, "window-closed");
  assert.equal(closeError.code, "ELECTRON_DEBUGGER_DETACHED");
  assert.equal(client.heartbeatTimer, null, "main detach left the client heartbeat active");
  assert.equal(fixture.webContents[Symbol.for("codex.remote-enabler.electron-attach.state.v1")], undefined);
  assert.equal(fixture.context.globalThis[client.identity.bindingName], undefined, "main detach left the binding global behind");
  client.close();
  await client.cleanupPromise;
}

async function testRejectedHeartbeatCleanup() {
  const fixture = makeFixture();
  const client = await connect(fixture);
  const bindingName = client.identity.bindingName;
  let closeCount = 0;
  let closeError;
  client.onClose((error) => { closeCount += 1; closeError = error; });
  fixture.mainClients[0].failNextEvaluation = Object.assign(new Error("fixture heartbeat failed"), { code: "FIXTURE_HEARTBEAT_FAILED" });
  await client._heartbeat();
  await client.cleanupPromise;
  assert.equal(closeCount, 1, "a rejected heartbeat did not emit exactly one close notification");
  assert.equal(closeError.code, "FIXTURE_HEARTBEAT_FAILED");
  assert.equal(client.closed, true, "a rejected heartbeat did not close the client");
  assert.equal(client.heartbeatTimer, null, "a rejected heartbeat left its timer active");
  assert.equal(fixture.context.globalThis[bindingName], undefined, "a rejected heartbeat left its owned binding global behind");
  assert.equal(fixture.webContents[Symbol.for("codex.remote-enabler.electron-attach.state.v1")], undefined);
  await client._heartbeat();
  assert.equal(closeCount, 1, "a closed client emitted another heartbeat close notification");
}

async function main() {
  await testDiscoveryEvaluator();
  await testIndependentSessionsAndEvents();
  await testIdentityAndForeignOwnership();
  await testLeaseAndDetachCleanup();
  await testRejectedHeartbeatCleanup();
  process.stdout.write(`${JSON.stringify({ discovery: true, independentSessions: true, eventCorrelation: true, identityChecks: true, foreignOwnership: true, leaseConstants: true, detachCleanup: true, bindingCleanup: true, rejectedHeartbeatCleanup: true })}\n`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
