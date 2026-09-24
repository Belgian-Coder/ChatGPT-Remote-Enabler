// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Clean-room contributors

"use strict";

const crypto = require("node:crypto");

const BINDING_NAME = "__chatgptRemoteUpdateRequest";
const BINDING_OWNER_PROPERTY = "__chatgptRemoteUpdateOwnerV1";
const INTERNAL_NAME = "__CHATGPT_REMOTE_UPDATE_INTERNAL__";
const PUBLIC_NAME = "__CHATGPT_REMOTE_UPDATE__";
const TARGET_URL = "app://-/index.html";
const RENDERER_REQUEST_TIMEOUT_MS = 30_000;
const ACTIVITY_TIMEOUT_MS = 35_000;
const STATUS_STATES = new Set([
  "checking", "current", "available", "queued", "preparing", "closing",
  "updating", "restarting", "error", "unavailable",
]);
const REQUEST_ACTIONS = new Set(["check", "queue", "cancel", "history"]);
function bridgeError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function cleanMessage(value, fallback = null) {
  if (typeof value !== "string") return fallback;
  const cleaned = value.replace(/[\r\n\0]+/gu, " ").trim().slice(0, 320);
  return cleaned || fallback;
}

const HISTORY_STATES = new Set([...STATUS_STATES, "hot-reload-confirmed", "restart-confirmed", "cancelled", "checked"]);
function normalizeUpdateDetails(value) {
  if (!value || typeof value !== "object") return null;
  const version = input => typeof input === "string" && /^v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/u.test(input) && input.length <= 64 ? input : null;
  const now = Date.now();
  return {
    installedVersion: version(value.installedVersion),
    availableVersion: version(value.availableVersion),
    lastCheckedAt: Number.isFinite(value.lastCheckedAt) && value.lastCheckedAt > 0 && value.lastCheckedAt <= now + 60000 ? value.lastCheckedAt : null,
    historyAvailable: value.historyAvailable !== false,
    history: (Array.isArray(value.history) ? value.history : []).filter(entry => entry && HISTORY_STATES.has(entry.state)
      && Number.isFinite(entry.at) && entry.at > now - 90 * 86400000 && entry.at <= now + 60000)
      .slice(-100).map(entry => ({ at: entry.at, state: entry.state, version: version(entry.version) })),
  };
}

function canonicalStatus(value) {
  return {
    ...(value?.details ? { details: normalizeUpdateDetails(value.details) } : {}),
    canCancel: value?.canCancel === true,
    canQueue: value?.canQueue === true,
    message: cleanMessage(value?.message),
    state: STATUS_STATES.has(value?.state) ? value.state : "unavailable",
    version: typeof value?.version === "string" && value.version.length > 0 ? value.version : null,
  };
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function bootstrapSource(nonce, initialStatus, bindingName = BINDING_NAME, bindingOwnerToken = null) {
  const encodedBinding = JSON.stringify(bindingName);
  const encodedBindingOwner = JSON.stringify(BINDING_OWNER_PROPERTY);
  const encodedBindingOwnerToken = JSON.stringify(bindingOwnerToken);
  const encodedInternal = JSON.stringify(INTERNAL_NAME);
  const encodedNonce = JSON.stringify(nonce);
  const encodedPublic = JSON.stringify(PUBLIC_NAME);
  const encodedStatus = JSON.stringify(canonicalStatus(initialStatus));
  const encodedTargetUrl = JSON.stringify(TARGET_URL);
  return `(() => {
    if (globalThis.top !== globalThis) return { installed:false, topFrame:false };
    if (globalThis.location?.href !== ${encodedTargetUrl}) return { installed:false, topFrame:true };
    const bindingName = ${encodedBinding};
    const bindingOwner = ${encodedBindingOwner};
    const bindingOwnerToken = ${encodedBindingOwnerToken};
    const internalName = ${encodedInternal};
    const nonce = ${encodedNonce};
    const publicName = ${encodedPublic};
    const allowed = new Set(["check", "queue", "cancel", "history"]);
    const pending = new Map();
    let disposed = false;
    let status = ${encodedStatus};
    if (bindingOwnerToken !== null) {
      const binding = globalThis[bindingName];
      if (typeof binding !== "function") {
        return { installed:false, topFrame:true };
      }
      const owner = binding[bindingOwner];
      if (owner !== undefined && owner !== bindingOwnerToken) return { installed:false, topFrame:true };
      if (owner === undefined) {
        try { Object.defineProperty(binding, bindingOwner, { configurable:true, value:bindingOwnerToken }); }
        catch { return { installed:false, topFrame:true }; }
      }
      if (binding[bindingOwner] !== bindingOwnerToken) return { installed:false, topFrame:true };
    }
    const clone = (value) => ({ ...(value.details ? { details: JSON.parse(JSON.stringify(value.details)) } : {}), state: value.state, version: value.version, message: value.message, canCancel: value.canCancel, canQueue: value.canQueue });
    const existing = globalThis[internalName];
    if (existing?.nonce === nonce && existing.bindingName === bindingName
      && existing.bindingOwnerToken === bindingOwnerToken && typeof existing.setStatus === "function"
      && globalThis[publicName] && existing.setStatus(status) === true) {
      return { installed:true, topFrame:true };
    }
    try { globalThis[internalName]?.dispose?.("The update controller was replaced."); } catch {}
    let api;
    const internal = {
      nonce,
      bindingName,
      bindingOwnerToken,
      dispose(reason) {
        if (disposed) return true;
        disposed = true;
        for (const item of pending.values()) {
          clearTimeout(item.timer);
          item.reject(new Error(typeof reason === "string" && reason ? reason : "The update controller stopped."));
        }
        pending.clear();
        if (globalThis[publicName] === api) Reflect.deleteProperty(globalThis, publicName);
        if (globalThis[internalName] === internal) Reflect.deleteProperty(globalThis, internalName);
        return true;
      },
      receive(reply) {
        if (disposed || !reply || reply.nonce !== nonce || typeof reply.id !== "string") return false;
        const item = pending.get(reply.id);
        if (!item) return false;
        pending.delete(reply.id);
        clearTimeout(item.timer);
        if (reply.ok) item.resolve(clone(reply.status || status));
        else item.reject(new Error(typeof reply.error === "string" ? reply.error : "Update request failed."));
        return true;
      },
      setStatus(next) {
        if (disposed || !next || typeof next.state !== "string") return false;
        status = clone(next);
        try { globalThis.document?.dispatchEvent(new CustomEvent("chatgpt-remote-update-status", { detail: clone(status) })); } catch {}
        return true;
      },
    };
    api = Object.freeze({
      getStatus() { return clone(status); },
      request(action) {
        if (disposed) return Promise.reject(new Error("The update controller stopped."));
        if (!allowed.has(action)) return Promise.reject(new Error("Unsupported update action."));
        const binding = globalThis[bindingName];
        if (typeof binding !== "function") return Promise.reject(new Error("The update controller is unavailable."));
        const id = globalThis.crypto?.randomUUID?.() || (Date.now().toString(36) + Math.random().toString(36).slice(2));
        return new Promise((resolve, reject) => {
          const timer = setTimeout(() => {
            pending.delete(id);
            reject(new Error("The update controller did not respond within 30 seconds."));
          }, ${RENDERER_REQUEST_TIMEOUT_MS});
          timer.unref?.();
          pending.set(id, { reject, resolve, timer });
          try { binding(JSON.stringify({ nonce, id, action })); }
          catch (error) { clearTimeout(timer); pending.delete(id); reject(error); }
        });
      },
    });
    Object.defineProperty(globalThis, internalName, { configurable: true, value: internal });
    Object.defineProperty(globalThis, publicName, { configurable: true, value: api });
    internal.setStatus(status);
    return { installed:true, topFrame:true };
  })()`;
}

function bindingAvailableSource(bindingName) {
  return `(() => {
    try { return globalThis[${JSON.stringify(bindingName)}] === undefined; }
    catch { return false; }
  })()`;
}

function claimBindingSource(bindingName, ownerToken) {
  return `(() => {
    try {
      const binding = globalThis[${JSON.stringify(bindingName)}];
      if (typeof binding !== "function") return false;
      const property = ${JSON.stringify(BINDING_OWNER_PROPERTY)};
      const token = ${JSON.stringify(ownerToken)};
      const owner = binding[property];
      if (owner !== undefined && owner !== token) return false;
      Object.defineProperty(binding, property, { configurable:true, value:token });
      return binding[property] === token;
    } catch { return false; }
  })()`;
}

function deleteOwnedBindingSource(bindingName, ownerToken) {
  return `(() => {
    try {
      const binding = globalThis[${JSON.stringify(bindingName)}];
      if (typeof binding !== "function" || binding[${JSON.stringify(BINDING_OWNER_PROPERTY)}] !== ${JSON.stringify(ownerToken)}) return false;
      return Reflect.deleteProperty(globalThis, ${JSON.stringify(bindingName)});
    } catch { return false; }
  })()`;
}

function healthProofSource(nonce, bindingName, ownerToken) {
  return `(() => {
    try {
      const internal = globalThis[${JSON.stringify(INTERNAL_NAME)}];
      const api = globalThis[${JSON.stringify(PUBLIC_NAME)}];
      const binding = globalThis[${JSON.stringify(bindingName)}];
      return internal?.nonce === ${JSON.stringify(nonce)}
        && typeof internal?.setStatus === "function"
        && typeof api?.getStatus === "function"
        && typeof api?.request === "function"
        && typeof binding === "function"
        && binding[${JSON.stringify(BINDING_OWNER_PROPERTY)}] === ${JSON.stringify(ownerToken)};
    } catch { return false; }
  })()`;
}

function callbackSource(nonce, bindingName, ownerToken, method, value) {
  return `(() => {
    const internal = globalThis[${JSON.stringify(INTERNAL_NAME)}];
    if (internal?.nonce !== ${JSON.stringify(nonce)}
      || internal?.bindingName !== ${JSON.stringify(bindingName)}
      || internal?.bindingOwnerToken !== ${JSON.stringify(ownerToken)}) return false;
    return internal?.[${JSON.stringify(method)}]?.(${JSON.stringify(value)}) ?? false;
  })()`;
}

class CdpTransport {
  constructor(config, nonce, cdp, options = {}) {
    this.config = config;
    this.nonce = nonce;
    this.cdp = cdp;
    this.timeoutMs = options.timeoutMs ?? 10_000;
    this.activityTimeoutMs = Math.max(ACTIVITY_TIMEOUT_MS, this.timeoutMs);
    this.client = null;
    this.session = null;
    this.persistentIdentifier = null;
    this.requestHandler = null;
    this.lastStatus = canonicalStatus({ state: "unavailable" });
    this.attachPromise = null;
    this.reattachPromise = null;
    this.activityPromise = null;
    this.healthProbePromise = null;
    this.healthTimer = null;
    this.lastHealthProofAtUnixMs = null;
    this.bindingSequence = 0;
    this.reconnectGeneration = 0;
    this.closingExpected = false;
    this.closed = false;
    this.reattachInitialDelayMs = options.reattachInitialDelayMs ?? 100;
    this.reattachMaximumDelayMs = options.reattachMaximumDelayMs ?? 5_000;
    this.healthIntervalMs = options.healthIntervalMs ?? 5_000;
  }

  onRequest(handler) {
    this.requestHandler = handler;
  }

  setStatusProvider(provider) {
    this.statusProvider = provider;
  }

  #refreshStatus() {
    if (this.statusProvider) this.lastStatus = canonicalStatus(this.statusProvider());
  }

  setClosingExpected(expected) {
    this.closingExpected = expected === true;
    if (!this.closingExpected && !this.closed && !this.session) void this.#startReattach();
  }

  getHealth() {
    return {
      connected: this.session !== null && this.closed !== true && this.closingExpected !== true,
      rendererProofAtUnixMs: Number.isSafeInteger(this.lastHealthProofAtUnixMs) ? this.lastHealthProofAtUnixMs : null,
    };
  }

  #startHealthWatchdog() {
    if (this.healthTimer || this.closed) return;
    this.healthTimer = setInterval(() => { void this.probeHealth(); }, this.healthIntervalMs);
    this.healthTimer.unref?.();
  }

  #stopHealthWatchdog() {
    if (this.healthTimer) clearInterval(this.healthTimer);
    this.healthTimer = null;
  }

  #bindingIdentity() {
    this.bindingSequence += 1;
    const safeNonce = String(this.nonce).replace(/[^A-Za-z0-9]/gu, "").slice(0, 24) || "session";
    const suffix = `${this.bindingSequence.toString(36)}_${crypto.randomBytes(12).toString("hex")}`;
    return {
      bindingName: `${BINDING_NAME}_${safeNonce}_${suffix}`,
      bindingOwnerToken: `${safeNonce}:${suffix}`,
    };
  }

  async attach() {
    if (this.session) return;
    if (this.attachPromise) return this.attachPromise;
    if (this.reattachPromise) return this.reattachPromise;
    this.closed = false;
    const deadline = Date.now() + Math.max(this.timeoutMs, 1_000);
    this.attachPromise = this.#attachOnce(deadline).finally(() => {
      this.attachPromise = null;
    });
    const result = await this.attachPromise;
    this.#startHealthWatchdog();
    return result;
  }

  #callTimeout(deadline, maximum = this.timeoutMs) {
    const remaining = deadline - Date.now();
    if (remaining < 25) throw bridgeError("ATTACH_TIMEOUT", "Renderer attachment timed out.");
    return Math.min(maximum, remaining);
  }

  #exactTarget(targets) {
    const exact = targets.filter(
      (target) => (target?.type === "page" || target?.type === "webview") && target.url === TARGET_URL,
    );
    if (exact.length > 1) throw bridgeError("TARGET_AMBIGUOUS", `Expected one exact ${TARGET_URL} renderer target; found ${exact.length}.`);
    if (exact.length === 0) throw bridgeError("TARGET_NOT_FOUND", `No exact ${TARGET_URL} page or webview target was found.`);
    return exact[0];
  }

  #recordContext(session, context) {
    if (!Number.isInteger(context?.id)) return;
    session.contexts.set(context.id, context);
    if (context.auxData?.isDefault === true && context.auxData?.frameId === session.mainFrameId) {
      session.mainContextId = context.id;
      if (session.committed) this.#scheduleConvergence(session);
    }
  }

  #protocolEvent(session, method, params) {
    if (method === "Runtime.executionContextCreated") {
      this.#recordContext(session, params?.context);
      return;
    }
    if (method === "Runtime.executionContextDestroyed") {
      session.contexts.delete(params?.executionContextId);
      if (params?.executionContextId === session.mainContextId) session.mainContextId = null;
      return;
    }
    if (method === "Runtime.executionContextsCleared") {
      session.contexts.clear();
      session.mainContextId = null;
      return;
    }
    if (method === "Page.frameNavigated" && !params?.frame?.parentId) {
      if (params?.frame?.url !== TARGET_URL || typeof params.frame.id !== "string") {
        session.mainFrameId = null;
        session.mainContextId = null;
        return;
      }
      session.mainFrameId = params.frame.id;
      const context = [...session.contexts.values()].find(
        (item) => item.auxData?.isDefault === true && item.auxData?.frameId === session.mainFrameId,
      );
      session.mainContextId = context?.id ?? null;
      if (session.committed) this.#scheduleConvergence(session);
      return;
    }
    if (
      method === "Runtime.bindingCalled"
      && params?.name === session.bindingName
      && Number.isInteger(params.executionContextId)
      && params.executionContextId === session.mainContextId
    ) {
      void this.#bindingCalled(session, params.payload).catch(() => {});
    }
  }

  async #waitForMainContext(session, deadline) {
    while (!Number.isInteger(session.mainContextId)) {
      if (Date.now() >= deadline) throw bridgeError("MAIN_CONTEXT_NOT_FOUND", "The exact renderer main-frame context was not created.");
      await delay(Math.min(25, Math.max(1, deadline - Date.now())));
    }
  }

  async #evaluate(session, expression, timeoutMs = this.timeoutMs) {
    if (!Number.isInteger(session.mainContextId)) throw bridgeError("MAIN_CONTEXT_NOT_FOUND", "The renderer main-frame context is unavailable.");
    const response = await session.client.call("Runtime.evaluate", {
      awaitPromise: true,
      contextId: session.mainContextId,
      expression,
      generatePreview: false,
      returnByValue: true,
      userGesture: false,
    }, timeoutMs);
    if (response.exceptionDetails) {
      const detail = cleanMessage(
        response.exceptionDetails.exception?.description
          ?? response.exceptionDetails.exception?.value
          ?? response.exceptionDetails.text,
        "unknown renderer exception",
      );
      throw bridgeError("EVALUATION_FAILED", `Renderer evaluation failed: ${detail}`);
    }
    return response.result?.value;
  }

  async #removeBinding(client, bindingName, timeoutMs) {
    await client.call("Runtime.removeBinding", { name: bindingName }, timeoutMs);
  }

  async #deleteOwnedBinding(session, timeoutMs) {
    if (!session?.bindingName || !session?.bindingOwnerToken || !Number.isInteger(session.mainContextId)) return false;
    return this.#evaluate(
      session,
      deleteOwnedBindingSource(session.bindingName, session.bindingOwnerToken),
      timeoutMs,
    );
  }

  async #removePersistent(client, identifier, timeoutMs) {
    if (typeof identifier !== "string" || identifier.length === 0) return;
    try {
      await client.call("Page.removeScriptToEvaluateOnNewDocument", { identifier }, timeoutMs);
    } catch (error) {
      const alreadyAbsent = error?.code === "CDP_PROTOCOL_ERROR"
        && ((error.protocolCode == null && error.message === "Script not found")
          || (String(error.protocolCode) === "-32000"
            && /(?:^|:\s*)Script not found\s*$/u.test(error.message ?? "")));
      if (!alreadyAbsent) throw error;
    }
  }

  async #attachOnce(deadline) {
    const targets = await this.cdp.discoverTargets(this.config.rendererPort, this.#callTimeout(deadline));
    const target = this.#exactTarget(targets);
    const client = await this.cdp.connectTarget(target, this.config.rendererPort, this.#callTimeout(deadline));
    const session = {
      ...this.#bindingIdentity(),
      client,
      committed: false,
      contexts: new Map(),
      convergencePromise: null,
      convergenceRequested: false,
      mainContextId: null,
      mainFrameId: null,
      persistentIdentifier: null,
      requestIds: new Set(),
      unsubscribeClose: null,
      unsubscribeEvent: null,
    };
    session.unsubscribeEvent = client.onEvent((method, params) => this.#protocolEvent(session, method, params));
    session.unsubscribeClose = client.onClose(() => {
      if (session.committed) this.#socketClosed(session);
    });
    let bindingInstalled = false;
    try {
      await client.call("Page.enable", {}, this.#callTimeout(deadline));
      const frameTree = await client.call("Page.getFrameTree", {}, this.#callTimeout(deadline));
      const mainFrame = frameTree?.frameTree?.frame;
      if (typeof mainFrame?.id !== "string" || mainFrame.url !== TARGET_URL) {
        throw bridgeError("TARGET_INVALID", "The debugger target does not contain the exact renderer main frame.");
      }
      session.mainFrameId = mainFrame.id;
      await client.call("Runtime.enable", {}, this.#callTimeout(deadline));
      await this.#waitForMainContext(session, deadline);

      const bindingAvailable = await this.#evaluate(
        session,
        bindingAvailableSource(session.bindingName),
        this.#callTimeout(deadline),
      );
      if (bindingAvailable !== true) {
        throw bridgeError("BINDING_BUSY", "The renderer update binding name is already occupied.");
      }
      await client.call("Runtime.addBinding", { name: session.bindingName }, this.#callTimeout(deadline));
      bindingInstalled = true;
      const bindingClaimed = await this.#evaluate(
        session,
        claimBindingSource(session.bindingName, session.bindingOwnerToken),
        this.#callTimeout(deadline),
      );
      if (bindingClaimed !== true) {
        throw bridgeError("BINDING_UNAVAILABLE", "The renderer update binding could not be claimed safely.");
      }
      if (this.persistentIdentifier) {
        await this.#removePersistent(client, this.persistentIdentifier, this.#callTimeout(deadline));
        this.persistentIdentifier = null;
      }
      this.#refreshStatus();
      const source = bootstrapSource(this.nonce, this.lastStatus, session.bindingName, session.bindingOwnerToken);
      const persistent = await client.call("Page.addScriptToEvaluateOnNewDocument", { source }, this.#callTimeout(deadline));
      if (typeof persistent?.identifier !== "string" || persistent.identifier.length === 0) {
        throw bridgeError("PERSISTENT_SCRIPT_INVALID", "The debugger did not return an update bootstrap identifier.");
      }
      session.persistentIdentifier = persistent.identifier;
      this.persistentIdentifier = persistent.identifier;
      const proof = await this.#evaluate(session, source, this.#callTimeout(deadline));
      if (proof?.installed !== true || proof?.topFrame !== true) {
        throw bridgeError("BOOTSTRAP_FAILED", "The update bootstrap did not install in the exact top-frame context.");
      }
      this.#refreshStatus();
      const statusApplied = await this.#evaluateCallback(session, "setStatus", this.lastStatus, this.#callTimeout(deadline));
      if (statusApplied !== true) throw bridgeError("BOOTSTRAP_FAILED", "The update bootstrap did not accept its initial status.");
      if (this.closed || this.closingExpected) throw bridgeError("ATTACH_CANCELLED", "Renderer attachment was cancelled.");
      session.committed = true;
      this.session = session;
      this.client = client;
      this.lastHealthProofAtUnixMs = Date.now();
      return;
    } catch (error) {
      session.committed = false;
      session.unsubscribeClose?.();
      session.unsubscribeEvent?.();
      try { await this.#evaluateCallback(session, "dispose", "The update controller could not attach.", 250); } catch {}
      try {
        await this.#removePersistent(client, session.persistentIdentifier, 250);
        if (session.persistentIdentifier === this.persistentIdentifier) this.persistentIdentifier = null;
      } catch {}
      if (bindingInstalled) {
        try { await this.#deleteOwnedBinding(session, 250); } catch {}
        try { await this.#removeBinding(client, session.bindingName, 250); } catch {}
      }
      client.close();
      throw error;
    }
  }

  #invalidateSession(session) {
    if (this.session !== session) return;
    session.committed = false;
    session.unsubscribeClose?.();
    session.unsubscribeEvent?.();
    this.session = null;
    this.client = null;
    this.lastHealthProofAtUnixMs = null;
    void (async () => {
      try { await this.#evaluateCallback(session, "dispose", "The update controller connection was lost.", 250); } catch {}
      try {
        await this.#removePersistent(session.client, session.persistentIdentifier, 250);
        if (session.persistentIdentifier === this.persistentIdentifier) this.persistentIdentifier = null;
      } catch {}
      try { await this.#deleteOwnedBinding(session, 250); } catch {}
      try { await this.#removeBinding(session.client, session.bindingName, 250); } catch {}
      try { session.client.close(); } catch {}
      if (!this.closed && !this.closingExpected) void this.#startReattach();
    })();
  }

  #socketClosed(session) {
    this.#invalidateSession(session);
  }

  #startReattach() {
    if (this.session || this.closed || this.closingExpected) return Promise.resolve();
    if (this.reattachPromise) return this.reattachPromise;
    const generation = ++this.reconnectGeneration;
    this.reattachPromise = (async () => {
      let retryDelay = Math.max(1, this.reattachInitialDelayMs);
      while (!this.closed && !this.closingExpected && generation === this.reconnectGeneration) {
        try {
          const attemptDeadline = Date.now() + Math.max(this.timeoutMs, 1_000);
          await this.#attachOnce(attemptDeadline);
          this.#startHealthWatchdog();
          return;
        } catch {
          await delay(retryDelay);
          retryDelay = Math.min(this.reattachMaximumDelayMs, Math.max(retryDelay + 1, retryDelay * 2));
        }
      }
    })().finally(() => {
      this.reattachPromise = null;
    });
    this.reattachPromise.catch(() => {});
    return this.reattachPromise;
  }

  async #requireSession() {
    if (this.session) return this.session;
    if (this.closed || this.closingExpected) return null;
    const pending = this.attachPromise ?? this.#startReattach();
    await Promise.race([pending, delay(Math.max(this.timeoutMs, 1_000))]);
    return this.session;
  }

  async #bindingCalled(session, payloadText) {
    if (typeof payloadText !== "string" || payloadText.length > 4096 || this.session !== session) return;
    let request;
    try { request = JSON.parse(payloadText); } catch { return; }
    if (!request || request.nonce !== this.nonce || typeof request.id !== "string"
      || !/^[A-Za-z0-9._:-]{1,128}$/u.test(request.id) || !REQUEST_ACTIONS.has(request.action)
      || Object.keys(request).some((key) => !["nonce", "id", "action"].includes(key))
      || session.requestIds.has(request.id)) return;
    session.requestIds.add(request.id);
    let reply;
    try {
      if (typeof this.requestHandler !== "function") throw new Error("The update request handler is unavailable.");
      const status = canonicalStatus(await this.requestHandler(request.action, request.id));
      reply = { nonce: this.nonce, id: request.id, ok: true, status };
    } catch (error) {
      reply = { nonce: this.nonce, id: request.id, ok: false, error: cleanMessage(error?.message, "Update request failed.") };
    } finally {
      session.requestIds.delete(request.id);
    }
    if (this.session === session) await this.#evaluateCallback(session, "receive", reply).catch(() => {});
  }

  async #evaluateCallback(session, method, value, timeoutMs = this.timeoutMs) {
    const expression = callbackSource(this.nonce, session.bindingName, session.bindingOwnerToken, method, value);
    return this.#evaluate(session, expression, timeoutMs);
  }

  #scheduleConvergence(session) {
    if (this.session !== session) return;
    session.convergenceRequested = true;
    if (session.convergencePromise) return;
    session.convergencePromise = (async () => {
      do {
        session.convergenceRequested = false;
        const deadline = Date.now() + Math.min(5_000, Math.max(1_000, this.timeoutMs));
        while (this.session === session && Date.now() < deadline) {
          if (Number.isInteger(session.mainContextId)) {
            try {
              this.#refreshStatus();
              if (await this.#evaluateCallback(session, "setStatus", this.lastStatus, Math.min(this.timeoutMs, Math.max(25, deadline - Date.now()))) === true) {
                return;
              }
            } catch {}
          }
          await delay(Math.min(50, Math.max(1, deadline - Date.now())));
        }
      } while (session.convergenceRequested && this.session === session);
    })().finally(() => {
      session.convergencePromise = null;
    });
    session.convergencePromise.catch(() => {});
  }

  async publish(status) {
    this.lastStatus = canonicalStatus(status);
    const session = await this.#requireSession();
    if (!session) throw bridgeError("RENDERER_UNAVAILABLE", "The renderer update bridge is unavailable.");
    try {
      const applied = await this.#evaluateCallback(session, "setStatus", this.lastStatus);
      if (applied !== true) throw bridgeError("BOOTSTRAP_UNAVAILABLE", "The renderer update bootstrap is unavailable.");
    } catch (error) {
      this.#invalidateSession(session);
      throw error;
    }
  }

  async probeHealth() {
    if (this.healthProbePromise) return this.healthProbePromise;
    this.healthProbePromise = (async () => {
      const session = this.session;
      if (!session || this.closed || this.closingExpected) {
        if (!this.closed && !this.closingExpected) void this.#startReattach();
        return false;
      }
      try {
        const healthy = await this.#evaluate(
          session,
          healthProofSource(this.nonce, session.bindingName, session.bindingOwnerToken),
          Math.min(this.timeoutMs, 2_000),
        );
        if (healthy !== true) {
          throw bridgeError("BOOTSTRAP_UNAVAILABLE", "The renderer update bootstrap health proof failed.");
        }
        this.lastHealthProofAtUnixMs = Date.now();
        return true;
      } catch {
        this.#invalidateSession(session);
        return false;
      }
    })().finally(() => { this.healthProbePromise = null; });
    return this.healthProbePromise;
  }

  async queryActivity() {
    if (this.activityPromise) return this.activityPromise;
    this.activityPromise = (async () => {
      const session = await this.#requireSession();
      if (!session) return { known: false, busy: false, reason: "The renderer is unavailable." };
      const value = await this.#evaluate(
        session,
        `Promise.resolve(globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__?.updateActivity?.())
          .then((value) => value && typeof value === "object" ? value : ({ known:false, busy:false, reason:"Task activity is unavailable." }))`,
        this.activityTimeoutMs,
      );
      if (!value || value.known !== true || typeof value.busy !== "boolean") {
        return { known: false, busy: false, reason: cleanMessage(value?.reason, "Waiting for authoritative task activity.") };
      }
      return { known: true, busy: value.busy, reason: cleanMessage(value.reason) };
    })().finally(() => {
      this.activityPromise = null;
    });
    return this.activityPromise;
  }

  async close() {
    this.closed = true;
    this.closingExpected = true;
    this.#stopHealthWatchdog();
    this.reconnectGeneration += 1;
    await Promise.allSettled([this.attachPromise, this.reattachPromise].filter(Boolean));
    const session = this.session;
    this.session = null;
    this.client = null;
    if (session) {
      session.committed = false;
      session.unsubscribeClose?.();
      session.unsubscribeEvent?.();
      try { await this.#evaluateCallback(session, "dispose", "The update controller stopped.", 500); } catch {}
      try {
        await this.#removePersistent(session.client, session.persistentIdentifier, 500);
        if (session.persistentIdentifier === this.persistentIdentifier) this.persistentIdentifier = null;
      } catch {}
      try { await this.#deleteOwnedBinding(session, 500); } catch {}
      try { await this.#removeBinding(session.client, session.bindingName, 500); } catch {}
      session.client.close();
    }
  }

}

module.exports = {
  normalizeUpdateDetails, BINDING_NAME, TARGET_URL, CdpTransport, bootstrapSource, callbackSource };
