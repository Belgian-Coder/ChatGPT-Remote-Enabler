// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Clean-room contributors

(function cleanroomMainPayloadFactory() {
  "use strict";

  const TARGET_ADDON_BASENAME = "remote-control-device-key.node";
  const ALGORITHM = "ecdsa_p256_sha256";
  const PROTECTION_MODE = "allow_os_protected_nonextractable";
  const PROTECTION_CLASS = "os_protected_nonextractable";
  const STORE_FILENAME = "remote-control-device-keys.windows.json";
  const INJECT_OPTIONS_SLOT = "__CODEX_CLEANROOM_MAIN_OPTIONS__";
  const STATE_SYMBOL = Symbol.for("codex.cleanroom.device-key-bridge.state.v1");
  const PROXY_STATE_SYMBOL = Symbol.for("codex.cleanroom.remote-control-proxy.state.v1");
  const REMOTE_CONTROL_PATH_PREFIXES = Object.freeze([
    "/backend-api/wham/remote/control/",
    "/backend-api/codex/remote/control/",
  ]);

  function builtin(name) {
    if (typeof process.getBuiltinModule === "function") {
      return process.getBuiltinModule(name);
    }
    if (typeof require === "function") {
      return require(name);
    }
    throw bridgeError("BUILTIN_UNAVAILABLE", `Node builtin is unavailable: ${name}`);
  }

  const fs = builtin("fs");
  const path = builtin("path");
  const os = builtin("os");
  const childProcess = builtin("child_process");
  const https = builtin("https");
  const net = builtin("net");
  const tls = builtin("tls");
  const Module = builtin("module");

  function supportsDeviceKeyCrypto(candidate) {
    return (
      candidate != null &&
      typeof candidate.createPrivateKey === "function" &&
      typeof candidate.createPublicKey === "function" &&
      typeof candidate.randomUUID === "function" &&
      typeof candidate.sign === "function" &&
      typeof candidate.timingSafeEqual === "function" &&
      (typeof candidate.generateKeyPair === "function" || typeof candidate.generateKeyPairSync === "function")
    );
  }

  function loadNodeCrypto() {
    const attempts = [];
    const accept = (label, candidate) => {
      if (supportsDeviceKeyCrypto(candidate)) return candidate;
      const missing = ["createPrivateKey", "createPublicKey", "randomUUID", "sign", "timingSafeEqual"]
        .filter((name) => typeof candidate?.[name] !== "function");
      if (typeof candidate?.generateKeyPair !== "function" && typeof candidate?.generateKeyPairSync !== "function") missing.push("generateKeyPair");
      attempts.push(`${label}:${missing.join(",") || "unavailable"}`);
      return null;
    };
    if (typeof process.getBuiltinModule === "function") {
      for (const name of ["node:crypto", "crypto"]) {
        try {
          const accepted = accept(`getBuiltinModule(${name})`, process.getBuiltinModule(name));
          if (accepted) return accepted;
        } catch {
          attempts.push(`getBuiltinModule(${name}):threw`);
        }
      }
    }
    const moduleCandidates = [Module];
    if (typeof process.getBuiltinModule === "function") {
      for (const name of ["node:module", "module"]) {
        try {
          const candidate = process.getBuiltinModule(name);
          if (candidate && !moduleCandidates.includes(candidate)) moduleCandidates.push(candidate);
        } catch {
          attempts.push(`getBuiltinModule(${name}):threw`);
        }
      }
    }
    for (const candidateModule of moduleCandidates) {
      if (typeof candidateModule?._load === "function") {
        for (const name of ["node:crypto", "crypto"]) {
          try {
            const accepted = accept(`Module._load(${name})`, candidateModule._load(name, null, false));
            if (accepted) return accepted;
          } catch {
            attempts.push(`Module._load(${name}):threw`);
          }
        }
      }
      if (typeof candidateModule?.createRequire === "function") {
        try {
          const loaderPath = path.join(os.tmpdir(), "codex-remote-node-loader.cjs");
          const accepted = accept("createRequire", candidateModule.createRequire(loaderPath)("node:crypto"));
          if (accepted) return accepted;
        } catch {
          attempts.push("createRequire:threw");
        }
      }
    }
    if (typeof process.mainModule?.require === "function") {
      try {
        const accepted = accept("process.mainModule.require", process.mainModule.require("node:crypto"));
        if (accepted) return accepted;
      } catch {
        attempts.push("process.mainModule.require:threw");
      }
    }
    if (typeof require === "function") {
      try {
        const accepted = accept("require", require("node:crypto"));
        if (accepted) return accepted;
      } catch {
        attempts.push("require:threw");
      }
    }
    try {
      const candidate = builtin("crypto");
      const accepted = accept("builtin", candidate);
      if (accepted) return accepted;
    } catch {
      attempts.push("builtin:threw");
    }
    throw bridgeError("CRYPTO_UNAVAILABLE", `A complete Node crypto module is required for Windows device keys (${attempts.join("; ").slice(0, 240)})`);
  }

  const crypto = loadNodeCrypto();

  function bridgeError(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
  }

  function parseProxyUrl(value) {
    if (typeof value !== "string" || value.trim().length === 0) {
      throw bridgeError("PROXY_URL_INVALID", "Proxy URL must be a non-empty string");
    }
    let parsed;
    try {
      parsed = new URL(value.trim());
    } catch {
      throw bridgeError("PROXY_URL_INVALID", "Proxy URL must be absolute");
    }
    if (!new Set(["http:", "https:"]).has(parsed.protocol) || parsed.hostname.length === 0) {
      throw bridgeError("PROXY_URL_INVALID", "Proxy URL must use http or https");
    }
    if (parsed.username.length > 0 || parsed.password.length > 0) {
      throw bridgeError("PROXY_CREDENTIALS_FORBIDDEN", "Proxy URL credentials are not accepted");
    }
    if ((parsed.pathname !== "" && parsed.pathname !== "/") || parsed.search.length > 0 || parsed.hash.length > 0) {
      throw bridgeError("PROXY_URL_INVALID", "Proxy URL may contain only scheme, host, and port");
    }
    return parsed;
  }

  function proxyPort(parsed) {
    if (parsed.port.length > 0) return Number(parsed.port);
    return parsed.protocol === "https:" ? 443 : 80;
  }

  function targetAuthority(hostname, port) {
    const host = String(hostname).replace(/^\[|\]$/gu, "");
    return `${net.isIP(host) === 6 ? `[${host}]` : host}:${port}`;
  }

  function trustedRootCertificates() {
    if (typeof tls.getCACertificates !== "function") return undefined;
    const certificates = [];
    for (const type of ["default", "system"]) {
      try {
        certificates.push(...tls.getCACertificates(type));
      } catch {
        // Older embedded Node versions may not expose every certificate store.
      }
    }
    return certificates.length > 0 ? [...new Set(certificates)] : undefined;
  }

  function createHttpConnectAgent(proxyUrl) {
    const proxy = parseProxyUrl(proxyUrl);
    const trustedCa = trustedRootCertificates();
    const agent = new https.Agent({ keepAlive: true });

    agent.createConnection = function createProxyTunnel(options, callback) {
      let settled = false;
      let proxySocket;
      const done = (error, socket) => {
        if (settled) return;
        settled = true;
        callback(error, socket);
      };
      const targetHost = String(options.servername ?? options.hostname ?? options.host ?? "").replace(/^\[|\]$/gu, "");
      const targetPort = Number(options.port ?? 443);
      if (targetHost.length === 0 || !Number.isInteger(targetPort) || targetPort < 1 || targetPort > 65535) {
        queueMicrotask(() => done(bridgeError("PROXY_TARGET_INVALID", "Remote-control proxy target is invalid")));
        return undefined;
      }

      const proxyConnectOptions = { host: proxy.hostname, port: proxyPort(proxy) };
      try {
        proxySocket = proxy.protocol === "https:"
          ? tls.connect({ ...proxyConnectOptions, ...(trustedCa ? { ca: trustedCa } : {}), servername: proxy.hostname })
          : net.connect(proxyConnectOptions);
      } catch {
        queueMicrotask(() => done(bridgeError("PROXY_CONNECT_FAILED", "Proxy connection could not be created")));
        return undefined;
      }

      const fail = (code, message) => {
        proxySocket?.destroy();
        done(bridgeError(code, message));
      };
      const onProxyError = () => fail("PROXY_CONNECT_FAILED", "Proxy connection failed");
      proxySocket.once("error", onProxyError);
      proxySocket.setTimeout(10_000, () => fail("PROXY_CONNECT_TIMEOUT", "Proxy CONNECT timed out"));

      const connectedEvent = proxy.protocol === "https:" ? "secureConnect" : "connect";
      proxySocket.once(connectedEvent, () => {
        const authority = targetAuthority(targetHost, targetPort);
        proxySocket.write([
          `CONNECT ${authority} HTTP/1.1`,
          `Host: ${authority}`,
          "Proxy-Connection: Keep-Alive",
          "Connection: Keep-Alive",
          "",
          "",
        ].join("\r\n"));
      });

      let response = Buffer.alloc(0);
      const onData = (chunk) => {
        response = Buffer.concat([response, chunk]);
        if (response.length > 16 * 1024) {
          fail("PROXY_RESPONSE_INVALID", "Proxy CONNECT response headers were too large");
          return;
        }
        const end = response.indexOf("\r\n\r\n");
        if (end < 0) return;

        proxySocket.removeListener("data", onData);
        proxySocket.removeListener("error", onProxyError);
        proxySocket.setTimeout(0);
        const statusLine = response.subarray(0, end).toString("latin1").split("\r\n", 1)[0] ?? "";
        const match = /^HTTP\/1\.[01]\s+(\d{3})(?:\s|$)/u.exec(statusLine);
        if (!match || Number(match[1]) !== 200) {
          fail("PROXY_CONNECT_REJECTED", `Proxy CONNECT was rejected with status ${match?.[1] ?? "unknown"}`);
          return;
        }

        const remainder = response.subarray(end + 4);
        if (remainder.length > 0) proxySocket.unshift(remainder);
        const tlsOptions = {
          socket: proxySocket,
          servername: options.servername ?? targetHost,
        };
        for (const name of [
          "ALPNProtocols",
          "ca",
          "cert",
          "checkServerIdentity",
          "ciphers",
          "clientCertEngine",
          "crl",
          "dhparam",
          "ecdhCurve",
          "honorCipherOrder",
          "key",
          "maxVersion",
          "minDHSize",
          "minVersion",
          "passphrase",
          "pfx",
          "rejectUnauthorized",
          "secureContext",
          "secureOptions",
          "secureProtocol",
          "session",
          "sigalgs",
        ]) {
          if (Object.prototype.hasOwnProperty.call(options, name)) {
            tlsOptions[name] = options[name];
          }
        }
        if (!Object.prototype.hasOwnProperty.call(options, "ca") && trustedCa) {
          tlsOptions.ca = trustedCa;
        }
        let secureSocket;
        try {
          secureSocket = tls.connect(tlsOptions);
        } catch {
          fail("PROXY_TLS_FAILED", "TLS over the proxy tunnel could not be created");
          return;
        }
        const onTlsError = () => {
          secureSocket.destroy();
          done(bridgeError("PROXY_TLS_FAILED", "TLS verification over the proxy tunnel failed"));
        };
        secureSocket.once("error", onTlsError);
        secureSocket.once("secureConnect", () => {
          secureSocket.removeListener("error", onTlsError);
          done(null, secureSocket);
        });
      };
      proxySocket.on("data", onData);
      return undefined;
    };
    return agent;
  }

  function isRemoteControlRequest(options) {
    if (options == null || typeof options !== "object" || options instanceof URL) return false;
    const hostname = String(options.hostname ?? options.host ?? "").replace(/^\[|\]$/gu, "").toLowerCase();
    const pathValue = String(options.path ?? options.pathname ?? "");
    return hostname === "chatgpt.com" && REMOTE_CONTROL_PATH_PREFIXES.some((prefix) => pathValue.startsWith(prefix));
  }

  function installRemoteControlProxyShim(proxyUrl) {
    if (globalThis[PROXY_STATE_SYMBOL]) {
      return { installed: true, reused: true, scope: "chatgpt-remote-control" };
    }
    const agent = createHttpConnectAgent(proxyUrl);
    const originalRequest = https.request;
    https.request = function cleanroomRemoteControlProxyRequest(options) {
      const args = Array.from(arguments);
      if (isRemoteControlRequest(options)) {
        args[0] = { ...options, agent };
      }
      return Reflect.apply(originalRequest, this, args);
    };
    globalThis[PROXY_STATE_SYMBOL] = { agent, originalRequest };
    return { installed: true, reused: false, scope: "chatgpt-remote-control" };
  }

  function isPlainObject(value) {
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
      return false;
    }
    const prototype = Object.getPrototypeOf(value);
    return prototype === Object.prototype || prototype === null;
  }

  function hasExactKeys(value, expected) {
    if (!isPlainObject(value)) {
      return false;
    }
    const actual = Object.keys(value).sort();
    const wanted = [...expected].sort();
    return actual.length === wanted.length && actual.every((key, index) => key === wanted[index]);
  }

  function decodeCanonicalBase64(value, label) {
    if (
      typeof value !== "string" ||
      value.length === 0 ||
      value.length % 4 !== 0 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(value)
    ) {
      throw bridgeError("STORE_MALFORMED", `${label} is not canonical base64`);
    }
    const decoded = Buffer.from(value, "base64");
    if (decoded.toString("base64") !== value) {
      throw bridgeError("STORE_MALFORMED", `${label} is not canonical base64`);
    }
    return decoded;
  }

  function validateKeyId(keyId) {
    if (typeof keyId !== "string" || keyId.length === 0 || keyId.length > 200 || !/^[A-Za-z0-9._-]+$/u.test(keyId)) {
      throw bridgeError("INVALID_KEY_ID", "Device key id is invalid");
    }
    return keyId;
  }

  function assertP256Key(keyObject, label) {
    if (keyObject.asymmetricKeyType !== "ec") {
      throw bridgeError("STORE_MALFORMED", `${label} is not an EC key`);
    }
    const curve = keyObject.asymmetricKeyDetails?.namedCurve;
    if (curve != null && !new Set(["prime256v1", "P-256", "secp256r1"]).has(curve)) {
      throw bridgeError("STORE_MALFORMED", `${label} is not a P-256 key`);
    }
  }

  function validatePublicSpki(base64, label) {
    const der = decodeCanonicalBase64(base64, label);
    try {
      const key = crypto.createPublicKey({ key: der, format: "der", type: "spki" });
      assertP256Key(key, label);
    } catch (error) {
      if (error?.code === "STORE_MALFORMED") {
        throw error;
      }
      throw bridgeError("STORE_MALFORMED", `${label} is not a valid P-256 SPKI key`);
    } finally {
      der.fill(0);
    }
  }

  function validateMetadata(record, label) {
    if (record.algorithm !== ALGORITHM || record.protectionClass !== PROTECTION_CLASS) {
      throw bridgeError("STORE_MALFORMED", `${label} has unsupported key metadata`);
    }
  }

  function parseV1Record(keyId, record) {
    const expected = [
      "algorithm",
      "encryptedPrivateKeyBase64",
      "protectionClass",
      "publicKeySpkiDerBase64",
    ];
    if (!hasExactKeys(record, expected)) {
      throw bridgeError("STORE_MALFORMED", `Version 1 record is malformed for key ${keyId}`);
    }
    validateMetadata(record, `Version 1 record ${keyId}`);
    validatePublicSpki(record.publicKeySpkiDerBase64, `Version 1 public key ${keyId}`);
    decodeCanonicalBase64(record.encryptedPrivateKeyBase64, `Version 1 protected key ${keyId}`).fill(0);
    return {
      algorithm: ALGORITHM,
      cipherBase64: record.encryptedPrivateKeyBase64,
      keyId,
      protectionClass: PROTECTION_CLASS,
      publicKeySpkiDerBase64: record.publicKeySpkiDerBase64,
      storageEncoding: "pkcs8-der",
    };
  }

  function parseLegacyRecord(keyId, record) {
    const expected = [
      "algorithm",
      "encryptedPrivateKeyBase64",
      "keyId",
      "protectionClass",
      "publicKeySpkiDerBase64",
    ];
    if (!hasExactKeys(record, expected)) {
      throw bridgeError("STORE_MALFORMED", `Legacy record is malformed for key ${keyId}`);
    }
    validateMetadata(record, `Legacy record ${keyId}`);
    if (record.keyId !== keyId) {
      throw bridgeError("STORE_MALFORMED", `Legacy record key id does not match its outer map key for key ${keyId}`);
    }
    const cipherBase64 = record.encryptedPrivateKeyBase64;
    decodeCanonicalBase64(cipherBase64, `Legacy protected key ${keyId}`).fill(0);
    const publicKeySpkiDerBase64 = record.publicKeySpkiDerBase64;
    validatePublicSpki(publicKeySpkiDerBase64, `Legacy public key ${keyId}`);
    return {
      algorithm: ALGORITHM,
      cipherBase64,
      keyId,
      protectionClass: PROTECTION_CLASS,
      publicKeySpkiDerBase64,
      storageEncoding: "pem",
    };
  }

  function parseStoreText(rawText) {
    let parsed;
    try {
      parsed = JSON.parse(rawText);
    } catch {
      throw bridgeError("STORE_MALFORMED", "Device key store is not valid JSON");
    }
    if (!isPlainObject(parsed)) {
      throw bridgeError("STORE_MALFORMED", "Device key store root must be an object");
    }

    const records = new Map();
    if (Object.hasOwn(parsed, "schemaVersion")) {
      if (!hasExactKeys(parsed, ["schemaVersion", "keys"]) || parsed.schemaVersion !== 1 || !isPlainObject(parsed.keys)) {
        throw bridgeError("STORE_SCHEMA_UNSUPPORTED", "Device key store schema is unsupported or malformed");
      }
      for (const [keyId, record] of Object.entries(parsed.keys)) {
        validateKeyId(keyId);
        records.set(keyId, parseV1Record(keyId, record));
      }
      return { kind: "v1", records };
    }

    if (Object.hasOwn(parsed, "keys")) {
      throw bridgeError("STORE_SCHEMA_UNSUPPORTED", "Unversioned nested device key stores are unsupported");
    }
    for (const [keyId, record] of Object.entries(parsed)) {
      validateKeyId(keyId);
      records.set(keyId, parseLegacyRecord(keyId, record));
    }
    return { kind: "legacy", records };
  }

  function serializeV1(records) {
    const keys = Object.create(null);
    for (const keyId of [...records.keys()].sort()) {
      const record = records.get(keyId);
      keys[keyId] = {
        algorithm: ALGORITHM,
        encryptedPrivateKeyBase64: record.encryptedPrivateKeyBase64,
        protectionClass: PROTECTION_CLASS,
        publicKeySpkiDerBase64: record.publicKeySpkiDerBase64,
      };
    }
    return `${JSON.stringify({ schemaVersion: 1, keys }, null, 2)}\n`;
  }

  function resolveCodexHome(options = {}) {
    const explicit = options.codexHome ?? process.env.CODEX_HOME;
    if (explicit != null) {
      if (typeof explicit !== "string" || explicit.trim().length === 0) {
        throw bridgeError("INVALID_CODEX_HOME", "CODEX_HOME must be a non-empty path");
      }
      return path.resolve(explicit.trim());
    }
    return path.join(os.homedir(), ".codex");
  }

  function resolveStorePath(options = {}) {
    if (options.storePath != null) {
      if (typeof options.storePath !== "string" || options.storePath.trim().length === 0) {
        throw bridgeError("INVALID_STORE_PATH", "Store path must be a non-empty path");
      }
      return path.resolve(options.storePath.trim());
    }
    return path.join(resolveCodexHome(options), STORE_FILENAME);
  }

  const DPAPI_SCRIPT = [
    "$ErrorActionPreference = 'Stop'",
    "Add-Type -AssemblyName System.Security",
    "$operation = '__OPERATION__'",
    "$encoded = [Console]::In.ReadToEnd().Trim()",
    "$inputBytes = [Convert]::FromBase64String($encoded)",
    "$scope = [System.Security.Cryptography.DataProtectionScope]::CurrentUser",
    "if ($operation -eq 'protect') {",
    "  $outputBytes = [System.Security.Cryptography.ProtectedData]::Protect($inputBytes, $null, $scope)",
    "} elseif ($operation -eq 'unprotect') {",
    "  $outputBytes = [System.Security.Cryptography.ProtectedData]::Unprotect($inputBytes, $null, $scope)",
    "} else {",
    "  throw 'invalid operation'",
    "}",
    "[Console]::Out.Write([Convert]::ToBase64String($outputBytes))",
  ].join(";");

  function resolveWindowsPowerShellPath(env = process.env) {
    const candidates = [env.SystemRoot, env.SYSTEMROOT, env.WINDIR, env.windir];
    for (const candidate of candidates) {
      if (typeof candidate !== "string" || candidate.trim().length === 0) {
        continue;
      }
      const windowsRoot = candidate.trim();
      if (!path.win32.isAbsolute(windowsRoot)) {
        continue;
      }
      return path.win32.join(
        path.win32.normalize(windowsRoot),
        "System32",
        "WindowsPowerShell",
        "v1.0",
        "powershell.exe",
      );
    }
    throw bridgeError("POWERSHELL_PATH_UNAVAILABLE", "An absolute SystemRoot or WINDIR is required for Windows DPAPI");
  }

  function runDpapi(operation, input, timeoutMs = 15_000) {
    if (operation !== "protect" && operation !== "unprotect") {
      return Promise.reject(bridgeError("DPAPI_OPERATION_INVALID", "DPAPI operation is invalid"));
    }
    if (process.platform !== "win32") {
      return Promise.reject(bridgeError("DPAPI_UNAVAILABLE", "Windows DPAPI is required"));
    }
    if (!Buffer.isBuffer(input) || input.length === 0) {
      return Promise.reject(bridgeError("DPAPI_INPUT_INVALID", "DPAPI input must be a non-empty buffer"));
    }

    return new Promise((resolve, reject) => {
      const operationScript = DPAPI_SCRIPT.replace("__OPERATION__", operation);
      let powershellPath;
      try {
        powershellPath = resolveWindowsPowerShellPath();
      } catch (error) {
        reject(error);
        return;
      }
      const child = childProcess.spawn(
        powershellPath,
        ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", operationScript],
        { stdio: ["pipe", "pipe", "pipe"], windowsHide: true },
      );
      const stdout = [];
      let stdoutBytes = 0;
      let settled = false;

      const finish = (error, output) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        if (error) {
          reject(error);
        } else {
          resolve(output);
        }
      };

      const timer = setTimeout(() => {
        child.kill();
        finish(bridgeError("DPAPI_TIMEOUT", `DPAPI ${operation} timed out`));
      }, timeoutMs);
      timer.unref?.();

      child.on("error", () => finish(bridgeError("DPAPI_START_FAILED", `DPAPI ${operation} could not start`)));
      child.stdout.on("data", (chunk) => {
        stdoutBytes += chunk.length;
        if (stdoutBytes > 32 * 1024 * 1024) {
          child.kill();
          finish(bridgeError("DPAPI_OUTPUT_INVALID", `DPAPI ${operation} returned excessive output`));
          return;
        }
        stdout.push(chunk);
      });
      child.stderr.resume();
      child.on("close", (code) => {
        if (code !== 0) {
          finish(bridgeError("DPAPI_FAILED", `DPAPI ${operation} failed`));
          return;
        }
        try {
          const encoded = Buffer.concat(stdout).toString("utf8").trim();
          const output = decodeCanonicalBase64(encoded, `DPAPI ${operation} output`);
          finish(null, output);
        } catch {
          finish(bridgeError("DPAPI_OUTPUT_INVALID", `DPAPI ${operation} returned invalid output`));
        }
      });
      child.stdin.on("error", () => {});
      child.stdin.end(input.toString("base64"));
    });
  }

  function generateP256Pair() {
    if (typeof crypto.generateKeyPair !== "function") {
      if (typeof crypto.generateKeyPairSync !== "function") {
        return Promise.reject(bridgeError("KEY_GENERATION_UNAVAILABLE", "Node P-256 key generation is unavailable"));
      }
      try {
        return Promise.resolve(crypto.generateKeyPairSync(
          "ec",
          {
            namedCurve: "prime256v1",
            privateKeyEncoding: { format: "der", type: "pkcs8" },
            publicKeyEncoding: { format: "der", type: "spki" },
          },
        )).then(({ privateKey, publicKey }) => ({ privateKey, publicKey }));
      } catch {
        return Promise.reject(bridgeError("KEY_GENERATION_FAILED", "P-256 key generation failed"));
      }
    }
    return new Promise((resolve, reject) => {
      crypto.generateKeyPair(
        "ec",
        {
          namedCurve: "prime256v1",
          privateKeyEncoding: { format: "der", type: "pkcs8" },
          publicKeyEncoding: { format: "der", type: "spki" },
        },
        (error, publicKey, privateKey) => {
          if (error) {
            reject(bridgeError("KEY_GENERATION_FAILED", "P-256 key generation failed"));
            return;
          }
          resolve({ privateKey, publicKey });
        },
      );
    });
  }

  function privateKeyFromPlaintext(plaintext, storageEncoding) {
    try {
      let key;
      if (storageEncoding === "pkcs8-der") {
        key = crypto.createPrivateKey({ key: plaintext, format: "der", type: "pkcs8" });
      } else if (storageEncoding === "pem") {
        const pem = plaintext.toString("utf8");
        if (!/^-----BEGIN (?:EC )?PRIVATE KEY-----\r?\n/u.test(pem) || !/\r?\n-----END (?:EC )?PRIVATE KEY-----\r?\n?$/u.test(pem)) {
          throw new Error("not PEM");
        }
        key = crypto.createPrivateKey(pem);
      } else {
        throw new Error("unknown encoding");
      }
      assertP256Key(key, "Protected private key");
      return key;
    } catch (error) {
      if (error?.code === "STORE_MALFORMED") {
        throw error;
      }
      throw bridgeError("STORE_UNREADABLE", "Protected device key material is unreadable");
    }
  }

  function publicSpkiFromPrivate(privateKey) {
    return crypto.createPublicKey(privateKey).export({ format: "der", type: "spki" });
  }

  class DeviceKeyService {
    constructor(options = {}) {
      this.storePath = resolveStorePath(options);
      this.dpapiTimeoutMs = options.dpapiTimeoutMs ?? 15_000;
      this.queue = Promise.resolve();
    }

    _enqueue(operation) {
      const result = this.queue.then(operation, operation);
      this.queue = result.catch(() => {});
      return result;
    }

    async _loadStore() {
      let rawText;
      try {
        rawText = await fs.promises.readFile(this.storePath, "utf8");
      } catch (error) {
        if (error?.code === "ENOENT") {
          return { kind: "v1", rawText: null, records: new Map() };
        }
        throw bridgeError("STORE_UNREADABLE", "Device key store cannot be read");
      }
      const parsed = parseStoreText(rawText);
      return { ...parsed, rawText };
    }

    async _loadPrivate(record) {
      const cipher = decodeCanonicalBase64(record.cipherBase64, `Protected key ${record.keyId}`);
      let plaintext;
      try {
        plaintext = await runDpapi("unprotect", cipher, this.dpapiTimeoutMs);
        const privateKey = privateKeyFromPlaintext(plaintext, record.storageEncoding);
        const derivedPublic = publicSpkiFromPrivate(privateKey);
        const derivedBase64 = derivedPublic.toString("base64");
        derivedPublic.fill(0);
        if (record.publicKeySpkiDerBase64 != null) {
          const stored = Buffer.from(record.publicKeySpkiDerBase64, "base64");
          const derived = Buffer.from(derivedBase64, "base64");
          const matches = stored.length === derived.length && crypto.timingSafeEqual(stored, derived);
          stored.fill(0);
          derived.fill(0);
          if (!matches) {
            throw bridgeError("STORE_UNREADABLE", "Protected private key does not match its public key");
          }
        }
        return { privateKey, publicKeySpkiDerBase64: derivedBase64 };
      } finally {
        cipher.fill(0);
        plaintext?.fill(0);
      }
    }

    async _validateAllPrivateRecords(store) {
      const loaded = new Map();
      for (const [keyId, record] of store.records) {
        loaded.set(keyId, await this._loadPrivate(record));
      }
      return loaded;
    }

    async _toWritableV1(store, loadedPrivate) {
      const records = new Map();
      for (const [keyId, record] of store.records) {
        const loaded = loadedPrivate.get(keyId);
        if (store.kind === "v1") {
          records.set(keyId, {
            encryptedPrivateKeyBase64: record.cipherBase64,
            publicKeySpkiDerBase64: loaded.publicKeySpkiDerBase64,
          });
          continue;
        }
        const privateDer = loaded.privateKey.export({ format: "der", type: "pkcs8" });
        try {
          const protectedDer = await runDpapi("protect", privateDer, this.dpapiTimeoutMs);
          records.set(keyId, {
            encryptedPrivateKeyBase64: protectedDer.toString("base64"),
            publicKeySpkiDerBase64: loaded.publicKeySpkiDerBase64,
          });
          protectedDer.fill(0);
        } finally {
          privateDer.fill(0);
        }
      }
      return records;
    }

    async _readCurrentRaw() {
      try {
        return await fs.promises.readFile(this.storePath, "utf8");
      } catch (error) {
        if (error?.code === "ENOENT") {
          return null;
        }
        throw bridgeError("STORE_UNREADABLE", "Device key store cannot be re-read safely");
      }
    }

    async _writeStore(records, expectedRawText) {
      const directory = path.dirname(this.storePath);
      await fs.promises.mkdir(directory, { recursive: true });
      const temporary = path.join(directory, `.${path.basename(this.storePath)}.${process.pid}.${crypto.randomUUID()}.tmp`);
      const serialized = serializeV1(records);
      let temporaryExists = false;
      try {
        await fs.promises.writeFile(temporary, serialized, { encoding: "utf8", flag: "wx", mode: 0o600 });
        temporaryExists = true;
        const currentRawText = await this._readCurrentRaw();
        if (currentRawText !== expectedRawText) {
          throw bridgeError("STORE_CHANGED", "Device key store changed during the operation");
        }
        await fs.promises.rename(temporary, this.storePath);
        temporaryExists = false;
      } finally {
        if (temporaryExists) {
          await fs.promises.unlink(temporary).catch(() => {});
        }
      }
    }

    createDeviceKey(mode) {
      return this._enqueue(async () => {
        if (mode !== PROTECTION_MODE) {
          throw bridgeError("PROTECTION_MODE_UNSUPPORTED", "Only OS-protected nonextractable device keys are supported");
        }
        const store = await this._loadStore();
        const loadedPrivate = await this._validateAllPrivateRecords(store);
        const writable = await this._toWritableV1(store, loadedPrivate);
        const { privateKey, publicKey } = await generateP256Pair();
        let protectedPrivate;
        try {
          protectedPrivate = await runDpapi("protect", privateKey, this.dpapiTimeoutMs);
          const keyId = crypto.randomUUID();
          const publicKeySpkiDerBase64 = publicKey.toString("base64");
          writable.set(keyId, {
            encryptedPrivateKeyBase64: protectedPrivate.toString("base64"),
            publicKeySpkiDerBase64,
          });
          await this._writeStore(writable, store.rawText);
          return {
            algorithm: ALGORITHM,
            keyId,
            protectionClass: PROTECTION_CLASS,
            publicKeySpkiDerBase64,
          };
        } finally {
          privateKey.fill(0);
          publicKey.fill(0);
          protectedPrivate?.fill(0);
        }
      });
    }

    deleteDeviceKey(keyId) {
      return this._enqueue(async () => {
        validateKeyId(keyId);
        const store = await this._loadStore();
        if (!store.records.has(keyId)) {
          throw bridgeError("KEY_NOT_FOUND", "Device key was not found");
        }
        const loadedPrivate = await this._validateAllPrivateRecords(store);
        const writable = await this._toWritableV1(store, loadedPrivate);
        writable.delete(keyId);
        await this._writeStore(writable, store.rawText);
      });
    }

    getDeviceKeyPublic(keyId) {
      return this._enqueue(async () => {
        validateKeyId(keyId);
        const store = await this._loadStore();
        const record = store.records.get(keyId);
        if (!record) {
          throw bridgeError("KEY_NOT_FOUND", "Device key was not found");
        }
        let publicKeySpkiDerBase64 = record.publicKeySpkiDerBase64;
        if (publicKeySpkiDerBase64 == null) {
          publicKeySpkiDerBase64 = (await this._loadPrivate(record)).publicKeySpkiDerBase64;
        }
        return {
          algorithm: ALGORITHM,
          keyId,
          protectionClass: PROTECTION_CLASS,
          publicKeySpkiDerBase64,
        };
      });
    }

    signDeviceKey(keyId, payload) {
      return this._enqueue(async () => {
        validateKeyId(keyId);
        const isUint8Array =
          payload != null &&
          ArrayBuffer.isView(payload) &&
          Object.prototype.toString.call(payload) === "[object Uint8Array]";
        if (!Buffer.isBuffer(payload) && !isUint8Array) {
          throw bridgeError("PAYLOAD_INVALID", "Signing payload must be bytes");
        }
        const bytes = Buffer.isBuffer(payload)
          ? Buffer.from(payload)
          : Buffer.from(new Uint8Array(payload.buffer, payload.byteOffset, payload.byteLength));
        const store = await this._loadStore();
        const record = store.records.get(keyId);
        if (!record) {
          throw bridgeError("KEY_NOT_FOUND", "Device key was not found");
        }
        const { privateKey } = await this._loadPrivate(record);
        const signature = crypto.sign("sha256", bytes, { key: privateKey, dsaEncoding: "der" });
        return { algorithm: ALGORITHM, signatureDerBase64: signature.toString("base64") };
      });
    }
  }

  function normalizedBasename(request) {
    if (typeof request !== "string") {
      return null;
    }
    const normalized = request.replace(/\\/gu, "/").replace(/\/+$/gu, "");
    const separator = normalized.lastIndexOf("/");
    return normalized.slice(separator + 1).toLowerCase();
  }

  function installPlatformStackShim() {
    const descriptor = Object.getOwnPropertyDescriptor(process, "platform");
    const actualPlatform = process.platform;
    if (!descriptor?.configurable) {
      return { installed: false, reason: "nonconfigurable" };
    }
    try {
      Object.defineProperty(process, "platform", {
        configurable: true,
        enumerable: descriptor.enumerable,
        get() {
          const stack = new Error().stack ?? "";
          return /\bgetAddon\b/u.test(stack) ? "darwin" : actualPlatform;
        },
      });
      return { installed: true, normalPlatform: actualPlatform };
    } catch {
      return { installed: false, reason: "define-failed" };
    }
  }

  function makeAddon(service) {
    return Object.freeze({
      createDeviceKey: service.createDeviceKey.bind(service),
      deleteDeviceKey: service.deleteDeviceKey.bind(service),
      getDeviceKeyPublic: service.getDeviceKeyPublic.bind(service),
      signDeviceKey: service.signDeviceKey.bind(service),
    });
  }

  function scheduleInspectorClose(delayMs) {
    let inspector;
    try {
      inspector = builtin("inspector");
    } catch {
      return { scheduled: false, reason: "inspector-unavailable" };
    }
    if (typeof inspector.close !== "function") {
      return { scheduled: false, reason: "close-unavailable" };
    }
    const boundedDelay = Math.max(25, Math.min(5_000, Number(delayMs) || 250));
    const timer = setTimeout(() => {
      try {
        inspector.close();
      } catch {
        // The orchestrator independently verifies the TCP refusal outcome.
      }
    }, boundedDelay);
    timer.unref?.();
    return { delayMs: boundedDelay, scheduled: true };
  }

  function installMainBridge(options = {}) {
    if (globalThis[STATE_SYMBOL]) {
      const reusedClose = options.scheduleInspectorClose === false ? { scheduled: false, reason: "disabled" } : scheduleInspectorClose(options.inspectorCloseDelayMs);
      return { ...globalThis[STATE_SYMBOL].report, inspectorClose: reusedClose, reused: true };
    }

    const service = new DeviceKeyService(options);
    const addon = makeAddon(service);
    const originalLoad = Module._load;
    const platformShim = options.spoofPlatform === false ? { installed: false, reason: "disabled" } : installPlatformStackShim();
    const proxyShim = options.proxyUrl == null
      ? { installed: false, reason: "disabled" }
      : installRemoteControlProxyShim(options.proxyUrl);
    if (options.interceptModules !== false) {
      Module._load = function cleanroomAddonLoad(request, parent, isMain) {
        if (normalizedBasename(request) === TARGET_ADDON_BASENAME) {
          return addon;
        }
        return originalLoad.apply(this, arguments);
      };
    }

    const report = {
      addonBasename: TARGET_ADDON_BASENAME,
      algorithm: ALGORITHM,
      installed: true,
      moduleInterception: options.interceptModules === false ? "disabled" : "installed",
      platformShim,
      proxyShim,
      protectionClass: PROTECTION_CLASS,
      status: "installed",
      store: "CODEX_HOME",
    };
    globalThis[STATE_SYMBOL] = { addon, originalLoad, proxyShim, report, service };
    const inspectorClose = options.scheduleInspectorClose === false ? { scheduled: false, reason: "disabled" } : scheduleInspectorClose(options.inspectorCloseDelayMs);
    return { ...report, inspectorClose, reused: false };
  }

  const api = Object.freeze({
    DeviceKeyService,
    createHttpConnectAgent,
    installMainBridge,
    installRemoteControlProxyShim,
    isRemoteControlRequest,
    normalizedBasename,
    parseStoreText,
    resolveCodexHome,
    resolveStorePath,
    resolveWindowsPowerShellPath,
    runDpapi,
  });

  const injectionOptions = globalThis[INJECT_OPTIONS_SLOT];
  if (isPlainObject(injectionOptions) && injectionOptions.inject === true) {
    delete globalThis[INJECT_OPTIONS_SLOT];
    return installMainBridge(injectionOptions);
  }
  if (typeof module === "object" && module != null && module.exports != null) {
    module.exports = api;
  }
  return api;
})();
