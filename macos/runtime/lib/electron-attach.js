// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Clean-room contributors

"use strict";

const TARGET_URL = "app://-/index.html";
const TARGET_MARKER = "codex-electron-attach-v1";
const STATE_SYMBOL_KEY = "codex.remote-enabler.electron-attach.state.v1";
const BINDING_OWNER_PROPERTY = "__codexElectronAttachOwnerV1";
const LEASE_HEARTBEAT_MS = 10_000;
const LEASE_EXPIRY_MS = 35_000;

let nextClientId = 1;

function transportError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function cleanErrorMessage(value, fallback = "Electron debugger operation failed") {
  if (typeof value !== "string") return fallback;
  const message = value.replace(/[\r\n\0]+/gu, " ").trim().slice(0, 320);
  return message || fallback;
}

function randomPart() {
  try {
    const crypto = require("node:crypto");
    if (typeof crypto.randomUUID === "function") return crypto.randomUUID().replace(/-/gu, "");
  } catch {
    // The fallback is sufficient for a local debugger binding name.
  }
  return `${Date.now().toString(36)}${Math.random().toString(36).slice(2)}`;
}

function createClientIdentity() {
  const sequence = nextClientId++;
  const suffix = randomPart();
  return {
    bindingName: `__codexElectronAttach_${process.pid}_${sequence}_${suffix}`,
    sessionToken: `codex-electron-session-${process.pid}-${sequence}-${suffix}`,
  };
}

function serialized(value) {
  return JSON.stringify(value).replace(/\u2028/gu, "\\u2028").replace(/\u2029/gu, "\\u2029");
}

function buildElectronLoadSource() {
  return [
    "const moduleBuiltin = process.getBuiltinModule?.('module');",
    "if (!moduleBuiltin || typeof moduleBuiltin.createRequire !== 'function') throw Object.assign(new Error('Electron module loader is unavailable'), { code: 'ELECTRON_LOADER_UNAVAILABLE' });",
    "const electronRequire = moduleBuiltin.createRequire(process.resourcesPath + '/app.asar/package.json');",
    "const electron = electronRequire('electron');",
  ].join("\n");
}

function buildDiscoveryExpression() {
  return `(() => {
    try {
      if (process.type !== "browser") return { ok: false, reason: "process-type" };
      const executable = String(process.execPath || "").replace(/\\\\/gu, "/").split("/").pop();
      if (!/^ChatGPT(?:\\.exe)?$/u.test(executable)) return { ok: false, reason: "executable" };
      ${buildElectronLoadSource()}
      const webContents = electron?.webContents;
      if (!webContents || typeof webContents.getAllWebContents !== "function") {
        return { ok: false, reason: "webContents-unavailable" };
      }
      const targets = [];
      for (const wc of webContents.getAllWebContents()) {
        let url;
        try { url = typeof wc.getURL === "function" ? wc.getURL() : ""; } catch { url = ""; }
        if (url !== ${serialized(TARGET_URL)} || !Number.isInteger(wc.id)) continue;
        targets.push({ id: wc.id, url });
      }
      return { ok: true, pid: process.pid, targets };
    } catch (error) {
      return { ok: false, reason: String(error?.code || error?.message || "electron-discovery-failed").slice(0, 160) };
    }
  })()`;
}

function buildClaimBindingExpression(identity) {
  const config = {
    bindingName: identity.bindingName,
    bindingOwnerProperty: BINDING_OWNER_PROPERTY,
    sessionToken: identity.sessionToken,
  };
  return `(() => {
    const config = ${serialized(config)};
    try {
      const binding = globalThis[config.bindingName];
      if (typeof binding !== "function") return false;
      const owner = binding[config.bindingOwnerProperty];
      if (owner !== undefined && owner !== config.sessionToken) return false;
      Object.defineProperty(binding, config.bindingOwnerProperty, { value: config.sessionToken, configurable: true });
      return binding[config.bindingOwnerProperty] === config.sessionToken;
    } catch { return false; }
  })()`;
}

function buildBindingAvailabilityExpression(identity) {
  const config = { bindingName: identity.bindingName };
  return `(() => {
    const config = ${serialized(config)};
    try { return globalThis[config.bindingName] === undefined; } catch { return false; }
  })()`;
}

function buildDeleteBindingExpression(identity) {
  const config = {
    bindingName: identity.bindingName,
    bindingOwnerProperty: BINDING_OWNER_PROPERTY,
    sessionToken: identity.sessionToken,
  };
  return `(() => {
    const config = ${serialized(config)};
    try {
      const binding = globalThis[config.bindingName];
      if (typeof binding !== "function" || binding[config.bindingOwnerProperty] !== config.sessionToken) return false;
      return delete globalThis[config.bindingName];
    } catch { return false; }
  })()`;
}

function buildBootstrapExpression(target, identity) {
  const config = {
    expectedPid: target.expectedPid,
    expectedUrl: target.expectedUrl || TARGET_URL,
    webContentsId: target.webContentsId,
    bindingName: identity.bindingName,
    sessionToken: identity.sessionToken,
    stateSymbolKey: STATE_SYMBOL_KEY,
    bindingOwnerProperty: BINDING_OWNER_PROPERTY,
    leaseExpiryMs: LEASE_EXPIRY_MS,
  };
  return `(async () => {
    const config = ${serialized(config)};
    const fail = (code, message) => ({ ok: false, error: { code, message } });
    const isOwnedBinding = (name, token) => {
      try { return typeof globalThis[name] === "function" && globalThis[name][config.bindingOwnerProperty] === token; } catch { return false; }
    };
    const deleteOwnedBinding = (name, token) => {
      if (!isOwnedBinding(name, token)) return false;
      try { return delete globalThis[name]; } catch { return false; }
    };
    if (!isOwnedBinding(config.bindingName, config.sessionToken)) {
      return fail("ELECTRON_BINDING_UNAVAILABLE", "The renderer binding was not owned by this client.");
    }
    const exactEnvironment = (wc) => {
      if (process.type !== "browser") return fail("ELECTRON_PROCESS_INVALID", "The main process is not an Electron browser process.");
      const executable = String(process.execPath || "").replace(/\\\\/gu, "/").split("/").pop();
      if (!/^ChatGPT(?:\\.exe)?$/u.test(executable)) return fail("ELECTRON_PROCESS_INVALID", "The main process executable is not ChatGPT.");
      if (process.pid !== config.expectedPid) return fail("ELECTRON_PROCESS_CHANGED", "The Electron process changed before attachment.");
      let url;
      try { url = typeof wc?.getURL === "function" ? wc.getURL() : ""; } catch { url = ""; }
      if (url !== config.expectedUrl || url !== ${serialized(TARGET_URL)}) return fail("ELECTRON_TARGET_CHANGED", "The renderer URL changed before attachment.");
      if (!wc || wc.isDestroyed?.()) return fail("ELECTRON_TARGET_DESTROYED", "The renderer webContents was destroyed.");
      return null;
    };
    let state = null;
    try {
      ${buildElectronLoadSource()}
      const webContents = electron?.webContents;
      const wc = webContents?.fromId?.(config.webContentsId);
      const invalid = exactEnvironment(wc);
      if (invalid) return invalid;
      const debuggerApi = wc.debugger;
      const debuggerAttached = () => {
        if (typeof debuggerApi?.isAttached !== "function") return null;
        try {
          return debuggerApi.isAttached() === true;
        } catch { return null; }
      };
      if (!debuggerApi || typeof debuggerApi.sendCommand !== "function" || typeof debuggerApi.isAttached !== "function") {
        return fail("ELECTRON_DEBUGGER_UNAVAILABLE", "The renderer debugger API is unavailable.");
      }
      const symbol = Symbol.for(config.stateSymbolKey);
      state = wc[symbol];
      if (state && (state.version !== 1 || state.debugger !== debuggerApi || state.attachedByUs !== true)) {
        return fail("ELECTRON_DEBUGGER_BUSY", "The renderer debugger is owned by another client.");
      }
      const attachedBefore = debuggerAttached();
      if (attachedBefore === null) {
        return fail("ELECTRON_DEBUGGER_STATE_UNAVAILABLE", "The renderer debugger attachment state could not be read.");
      }
      if (state && !attachedBefore) {
        try { state.detachAll?.("debugger-detached"); } catch { try { state.clearRoot?.(false); } catch {} }
        try { delete wc[symbol]; } catch {}
        state = null;
      }
      if (!state) {
        if (debuggerAttached() === null) {
          return fail("ELECTRON_DEBUGGER_STATE_UNAVAILABLE", "The renderer debugger attachment state could not be read.");
        }
        if (debuggerAttached() === true) {
          return fail("ELECTRON_DEBUGGER_BUSY", "The renderer debugger is already attached by another client.");
        }
        try { debuggerApi.attach(); }
        catch (error) { return fail(String(error?.code || "ELECTRON_DEBUGGER_ATTACH_FAILED"), String(error?.message || "The renderer debugger could not attach.")); }
        state = {
          version: 1,
          debugger: debuggerApi,
          attachedByUs: true,
          refs: 0,
          sessions: new Map(),
          closing: false,
          listener: null,
          detachListener: null,
          destroyedListener: null,
          timer: null,
        };
        const sendBinding = (name, payload, token) => {
          try {
            if (!isOwnedBinding(name, token)) return;
            const binding = globalThis[name];
            if (typeof binding === "function") binding(JSON.stringify(payload));
          } catch {}
        };
        state.listener = (_event, method, params, sessionId) => {
          if (typeof sessionId !== "string") return;
          for (const session of state.sessions.values()) {
            if (!session.closed && session.sessionId === sessionId) {
              sendBinding(session.bindingName, { kind: "message", sessionId, method, params: params ?? {} }, session.token);
            }
          }
        };
        state.clearRoot = (detach) => {
          state.closing = true;
          if (state.timer) clearInterval(state.timer);
          state.timer = null;
          if (typeof debuggerApi.removeListener === "function") {
            try { debuggerApi.removeListener("message", state.listener); } catch {}
            try { debuggerApi.removeListener("detach", state.detachListener); } catch {}
          }
          if (typeof wc.removeListener === "function" && state.destroyedListener) {
            try { wc.removeListener("destroyed", state.destroyedListener); } catch {}
          }
          let ownsCurrentState = false;
          try {
            ownsCurrentState = wc[symbol] === state;
            if (ownsCurrentState) delete wc[symbol];
          } catch {}
          if (detach && ownsCurrentState) {
            try {
              const attached = typeof debuggerApi.isAttached === "function" && debuggerApi.isAttached() === true;
              if (state.attachedByUs && attached) debuggerApi.detach();
            } catch {}
          }
        };
        state.detachAll = (reason) => {
          if (state.closing) return;
          for (const session of state.sessions.values()) {
            session.closed = true;
            sendBinding(session.bindingName, { kind: "detach", sessionId: session.sessionId, reason: String(reason || "detached") }, session.token);
            deleteOwnedBinding(session.bindingName, session.token);
          }
          state.sessions.clear();
          state.refs = 0;
          state.clearRoot(true);
        };
        state.release = async (token, reason) => {
          const session = state.sessions.get(token);
          if (!session || session.closed) return { released: false };
          if (reason !== "client-closed") {
            sendBinding(session.bindingName, { kind: "detach", sessionId: session.sessionId, reason: String(reason || "released") }, session.token);
          }
          deleteOwnedBinding(session.bindingName, session.token);
          session.closed = true;
          state.sessions.delete(token);
          state.refs = Math.max(0, state.refs - 1);
          if (typeof session.sessionId === "string") {
            try { await debuggerApi.sendCommand("Target.detachFromTarget", { sessionId: session.sessionId }); } catch {}
          }
          if (state.refs === 0) {
            state.clearRoot(true);
          }
          return { released: true, reason: String(reason || "released") };
        };
        state.sweepLeases = () => {
          const now = Date.now();
          for (const session of [...state.sessions.values()]) {
            if (!session.closed && now - session.lastHeartbeat > config.leaseExpiryMs) {
              void state.release(session.token, "lease-expired");
            }
          }
        };
        state.timer = setInterval(state.sweepLeases, ${LEASE_HEARTBEAT_MS});
        state.timer.unref?.();
        state.detachListener = (_event, reason) => state.detachAll(reason || "debugger-detached");
        if (typeof debuggerApi.on === "function") {
          debuggerApi.on("message", state.listener);
          debuggerApi.on("detach", state.detachListener);
        }
        state.destroyedListener = () => state.detachAll("window-destroyed");
        if (typeof wc.once === "function") wc.once("destroyed", state.destroyedListener);
        try { wc[symbol] = state; } catch {
          state.clearRoot(true);
          return fail("ELECTRON_STATE_UNAVAILABLE", "The renderer debugger state could not be retained.");
        }
      }
      const pendingSession = {
        token: config.sessionToken,
        bindingName: config.bindingName,
        sessionId: null,
        lastHeartbeat: Date.now(),
        closed: false,
      };
      state.sessions.set(config.sessionToken, pendingSession);
      state.refs += 1;
      const targetInfo = await debuggerApi.sendCommand("Target.getTargetInfo");
      const targetId = targetInfo?.targetInfo?.targetId;
      if (typeof targetId !== "string" || targetId.length === 0) {
        await state.release(config.sessionToken, "target-info-failed");
        return fail("ELECTRON_TARGET_INFO_INVALID", "The renderer debugger did not return a target id.");
      }
      const attached = await debuggerApi.sendCommand("Target.attachToTarget", { targetId, flatten: true });
      const sessionId = attached?.sessionId;
      if (typeof sessionId !== "string" || sessionId.length === 0) {
        await state.release(config.sessionToken, "session-attach-failed");
        return fail("ELECTRON_SESSION_INVALID", "The renderer debugger did not return a session id.");
      }
      pendingSession.sessionId = sessionId;
      return { ok: true, pid: process.pid, url: wc.getURL(), targetId, sessionId, refs: state.refs };
    } catch (error) {
      try { await state?.release?.(config.sessionToken, "attach-failed"); } catch {}
      return fail(String(error?.code || "ELECTRON_ATTACH_FAILED"), String(error?.message || "The renderer debugger could not attach."));
    }
  })()`;
}

function buildCommandExpression(target, identity, method, params) {
  const config = {
    expectedPid: target.expectedPid,
    expectedUrl: target.expectedUrl || TARGET_URL,
    webContentsId: target.webContentsId,
    bindingName: identity.bindingName,
    sessionToken: identity.sessionToken,
    sessionId: target.sessionId,
    stateSymbolKey: STATE_SYMBOL_KEY,
  };
  return `(async () => {
    const config = ${serialized(config)};
    const method = ${serialized(method)};
    const params = ${serialized(params ?? {})};
    const result = (ok, value) => ok ? { ok: true, result: value ?? {} } : { ok: false, error: value };
    try {
      if (process.type !== "browser" || !/^ChatGPT(?:\\.exe)?$/u.test(String(process.execPath || "").replace(/\\\\/gu, "/").split("/").pop())) {
        return result(false, { code: "ELECTRON_PROCESS_INVALID", message: "The Electron process identity changed." });
      }
      if (process.pid !== config.expectedPid) return result(false, { code: "ELECTRON_PROCESS_CHANGED", message: "The Electron process changed during the session." });
      ${buildElectronLoadSource()}
      const wc = electron?.webContents?.fromId?.(config.webContentsId);
      if (!wc || wc.isDestroyed?.() || wc.getURL?.() !== config.expectedUrl || wc.getURL?.() !== ${serialized(TARGET_URL)}) {
        return result(false, { code: "ELECTRON_TARGET_CHANGED", message: "The renderer target changed during the session." });
      }
      const state = wc[Symbol.for(config.stateSymbolKey)];
      const session = state?.sessions?.get(config.sessionToken);
      if (!state || !session || session.closed || session.sessionId !== config.sessionId) {
        return result(false, { code: "ELECTRON_SESSION_CLOSED", message: "The Electron renderer session is closed." });
      }
      session.lastHeartbeat = Date.now();
      try {
        return result(true, await state.debugger.sendCommand(method, params, session.sessionId));
      } catch (error) {
        return result(false, { code: String(error?.code || "CDP_PROTOCOL_ERROR"), protocolCode: Number.isInteger(error?.code) ? error.code : undefined, message: String(error?.message || "Electron debugger command failed") });
      }
    } catch (error) {
      return result(false, { code: String(error?.code || "ELECTRON_COMMAND_FAILED"), message: String(error?.message || "Electron debugger command failed") });
    }
  })()`;
}

function buildHeartbeatExpression(target, identity) {
  const config = {
    expectedPid: target.expectedPid,
    expectedUrl: target.expectedUrl || TARGET_URL,
    webContentsId: target.webContentsId,
    sessionToken: identity.sessionToken,
    sessionId: target.sessionId,
    stateSymbolKey: STATE_SYMBOL_KEY,
  };
  return `(() => {
    const config = ${serialized(config)};
    try {
      if (process.pid !== config.expectedPid) return false;
      ${buildElectronLoadSource()}
      const wc = electron?.webContents?.fromId?.(config.webContentsId);
      const session = wc?.[Symbol.for(config.stateSymbolKey)]?.sessions?.get(config.sessionToken);
      if (!session || session.closed || session.sessionId !== config.sessionId || wc.getURL?.() !== config.expectedUrl) return false;
      session.lastHeartbeat = Date.now();
      return true;
    } catch { return false; }
  })()`;
}

function buildReleaseExpression(target, identity) {
  const config = {
    webContentsId: target.webContentsId,
    sessionToken: identity.sessionToken,
    stateSymbolKey: STATE_SYMBOL_KEY,
  };
  return `(async () => {
    const config = ${serialized(config)};
    try {
      ${buildElectronLoadSource()}
      const wc = electron?.webContents?.fromId?.(config.webContentsId);
      const state = wc?.[Symbol.for(config.stateSymbolKey)];
      if (!state || typeof state.release !== "function") return { released: false };
      return await state.release(config.sessionToken, "client-closed");
    } catch { return { released: false }; }
  })()`;
}

function isElectronAttachTarget(target) {
  return target != null
    && typeof target === "object"
    && target._codexElectronAttachTarget === TARGET_MARKER
    && Number.isInteger(target.webContentsId)
    && Number.isInteger(target.expectedPid)
    && typeof (target.mainWebSocketDebuggerUrl || target.webSocketDebuggerUrl) === "string";
}

class ElectronAttachClient {
  constructor(target, options = {}) {
    this.target = target;
    this.timeoutMs = options.timeoutMs ?? 10_000;
    this.createMainClient = options.createMainClient;
    this.forceLoopbackWebSocketUrl = options.forceLoopbackWebSocketUrl;
    this.identity = createClientIdentity();
    this.mainClient = null;
    this.sessionId = null;
    this.targetId = null;
    this.connected = false;
    this.closed = false;
    this.bindingInstalled = false;
    this.closeNotified = false;
    this.eventHandlers = new Set();
    this.closeHandlers = new Set();
    this.unsubscribeEvent = null;
    this.unsubscribeClose = null;
    this.heartbeatTimer = null;
    this.heartbeatPromise = null;
    this.cleanupPromise = null;
  }

  async connect() {
    if (this.connected) return this;
    if (this.closed) throw transportError("WEBSOCKET_NOT_OPEN", "Electron debugger session is closed");
    if (typeof this.createMainClient !== "function" || typeof this.forceLoopbackWebSocketUrl !== "function") {
      throw transportError("ELECTRON_TRANSPORT_INVALID", "Electron debugger transport dependencies are unavailable");
    }
    const deadline = Date.now() + Math.max(25, this.timeoutMs);
    const activationTimeout = () => {
      const remaining = deadline - Date.now();
      if (remaining < 25) throw transportError("ELECTRON_ATTACH_TIMEOUT", "Electron renderer session attachment timed out");
      return remaining;
    };
    const reportedUrl = this.target.mainWebSocketDebuggerUrl || this.target.webSocketDebuggerUrl;
    const url = this.forceLoopbackWebSocketUrl(reportedUrl, this.target.port);
    const client = this.createMainClient(url, { timeoutMs: activationTimeout() });
    this.mainClient = client;
    this.unsubscribeEvent = client.onEvent((method, params) => this._onMainEvent(method, params));
    this.unsubscribeClose = client.onClose((error) => this._onMainClose(error));
    try {
      await client.connect();
      await client.call("Runtime.enable", {}, activationTimeout());
      const bindingAvailable = await this._evaluate(buildBindingAvailabilityExpression(this.identity), activationTimeout());
      if (bindingAvailable !== true) throw transportError("ELECTRON_BINDING_BUSY", "The Electron binding name is already occupied");
      await client.call("Runtime.addBinding", { name: this.identity.bindingName }, activationTimeout());
      this.bindingInstalled = true;
      const claimed = await this._evaluate(buildClaimBindingExpression(this.identity), activationTimeout());
      if (claimed !== true) throw transportError("ELECTRON_BINDING_UNAVAILABLE", "The Electron binding could not be claimed safely");
      const setup = await this._evaluate(buildBootstrapExpression(this.target, this.identity), activationTimeout());
      if (setup?.ok !== true || typeof setup.sessionId !== "string" || setup.sessionId.length === 0) {
        const detail = setup?.error;
        throw transportError(detail?.code || "ELECTRON_ATTACH_FAILED", detail?.message || "The Electron renderer session could not attach");
      }
      this.sessionId = setup.sessionId;
      this.targetId = setup.targetId;
      this.connected = true;
      this.heartbeatTimer = setInterval(() => { void this._heartbeat(); }, LEASE_HEARTBEAT_MS);
      this.heartbeatTimer.unref?.();
      if (this.closed) {
        this.close();
        throw transportError("ELECTRON_ATTACH_CANCELLED", "Electron debugger session was closed during attachment");
      }
      return this;
    } catch (error) {
      await this._cleanup().catch(() => {});
      throw error;
    }
  }

  _evaluate(expression, timeoutMs = this.timeoutMs) {
    return this.mainClient.call("Runtime.evaluate", {
      awaitPromise: true,
      expression,
      generatePreview: false,
      returnByValue: true,
      userGesture: false,
    }, timeoutMs).then((response) => {
      if (response?.exceptionDetails) {
        const detail = response.exceptionDetails.exception?.description
          ?? response.exceptionDetails.exception?.value
          ?? response.exceptionDetails.text;
        throw transportError("ELECTRON_EVALUATION_FAILED", cleanErrorMessage(detail));
      }
      return response?.result?.value;
    });
  }

  _onMainEvent(method, params) {
    if (method !== "Runtime.bindingCalled" || params?.name !== this.identity.bindingName || typeof params?.payload !== "string") return;
    let message;
    try { message = JSON.parse(params.payload); } catch { return; }
    if (!message || message.sessionId !== this.sessionId) return;
    if (message.kind === "message" && typeof message.method === "string") {
      for (const handler of this.eventHandlers) {
        try { handler(message.method, message.params ?? {}); } catch {}
      }
      return;
    }
    if (message.kind === "detach") {
      this._notifyClose(transportError("ELECTRON_DEBUGGER_DETACHED", `Electron renderer debugger detached (${String(message.reason || "unknown")})`));
      try { this.mainClient?.close(); } catch {}
    }
  }

  _onMainClose(error) {
    if (this.closeNotified) return;
    this.connected = false;
    this._clearHeartbeat();
    this._notifyClose(error?.code ? error : transportError("WEBSOCKET_CLOSED", "Electron main inspector connection closed"));
  }

  _notifyClose(error) {
    if (this.closeNotified) return;
    this.connected = false;
    this._clearHeartbeat();
    this.closeNotified = true;
    for (const handler of this.closeHandlers) {
      try { handler(error); } catch {}
    }
  }

  _clearHeartbeat() {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = null;
  }

  async _heartbeat() {
    if (!this.connected || this.closed || this.heartbeatPromise) return;
    this.heartbeatPromise = this._evaluate(buildHeartbeatExpression({ ...this.target, sessionId: this.sessionId }, this.identity), Math.min(this.timeoutMs, 2_000))
      .then((active) => {
        if (active !== true && !this.closed) {
          this._notifyClose(transportError("ELECTRON_SESSION_CLOSED", "The Electron renderer session is no longer active."));
          void this._cleanup();
        }
      })
      .catch((error) => {
        if (this.closed) return;
        this._notifyClose(error?.code ? error : transportError("ELECTRON_HEARTBEAT_FAILED", "The Electron renderer heartbeat failed."));
        void this._cleanup();
      })
      .finally(() => { this.heartbeatPromise = null; });
    await this.heartbeatPromise;
  }

  call(method, params = {}, timeoutMs = this.timeoutMs) {
    if (!this.connected || this.closed || !this.mainClient) {
      return Promise.reject(transportError("WEBSOCKET_NOT_OPEN", "Electron debugger session is not open"));
    }
    if (typeof method !== "string" || method.length === 0) {
      return Promise.reject(transportError("CDP_METHOD_INVALID", "Debugger method is invalid"));
    }
    let expression;
    try {
      expression = buildCommandExpression({ ...this.target, sessionId: this.sessionId }, this.identity, method, params);
    } catch {
      return Promise.reject(transportError("CDP_PARAMS_INVALID", "Debugger call parameters are not serializable"));
    }
    return this._evaluate(expression, timeoutMs)
      .then((response) => {
        if (!response?.ok) {
          const detail = response?.error;
          const error = transportError(detail?.code || "CDP_PROTOCOL_ERROR", cleanErrorMessage(detail?.message, `Electron debugger command failed: ${method}`));
          if (Number.isInteger(detail?.protocolCode)) error.protocolCode = detail.protocolCode;
          return Promise.reject(error);
        }
        return response.result ?? {};
      });
  }

  onEvent(handler) {
    this.eventHandlers.add(handler);
    return () => this.eventHandlers.delete(handler);
  }

  onClose(handler) {
    this.closeHandlers.add(handler);
    return () => this.closeHandlers.delete(handler);
  }

  _cleanup() {
    if (this.cleanupPromise) return this.cleanupPromise;
    this.closed = true;
    this.connected = false;
    this._clearHeartbeat();
    this.cleanupPromise = (async () => {
      const client = this.mainClient;
      if (!client) return;
      try {
        if (this.sessionId) {
          await this._evaluate(buildReleaseExpression(this.target, this.identity), Math.min(this.timeoutMs, 2_000)).catch(() => {});
        }
        if (this.bindingInstalled) {
          await client.call("Runtime.removeBinding", { name: this.identity.bindingName }, Math.min(this.timeoutMs, 2_000)).catch(() => {});
          await this._evaluate(buildDeleteBindingExpression(this.identity), Math.min(this.timeoutMs, 2_000)).catch(() => {});
        }
      } finally {
        this.bindingInstalled = false;
        this.unsubscribeEvent?.();
        this.unsubscribeClose?.();
        this.unsubscribeEvent = null;
        this.unsubscribeClose = null;
        try { client.close(); } catch {}
      }
    })().catch(() => {});
    return this.cleanupPromise;
  }

  close() {
    void this._cleanup();
  }
}

async function connectElectronTarget(target, port, timeoutMs, dependencies = {}) {
  if (!isElectronAttachTarget(target)) {
    throw transportError("TARGET_INVALID", "The debugger target is not an Electron attach target");
  }
  const client = new ElectronAttachClient(
    { ...target, port },
    {
      timeoutMs,
      createMainClient: dependencies.createMainClient,
      forceLoopbackWebSocketUrl: dependencies.forceLoopbackWebSocketUrl,
    },
  );
  await client.connect();
  return client;
}

module.exports = {
  ELECTRON_ATTACH_TARGET_MARKER: TARGET_MARKER,
  ELECTRON_ATTACH_LEASE_HEARTBEAT_MS: LEASE_HEARTBEAT_MS,
  ELECTRON_ATTACH_LEASE_EXPIRY_MS: LEASE_EXPIRY_MS,
  ELECTRON_TARGET_URL: TARGET_URL,
  ElectronAttachClient,
  buildBindingAvailabilityExpression,
  buildClaimBindingExpression,
  buildBootstrapExpression,
  buildCommandExpression,
  buildDeleteBindingExpression,
  buildDiscoveryExpression,
  buildHeartbeatExpression,
  buildReleaseExpression,
  connectElectronTarget,
  isElectronAttachTarget,
};
