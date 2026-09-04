"use strict";

const http = require("http");
const https = require("https");
const net = require("net");
const tls = require("tls");

const CONNECT_TIMEOUT_MS = 15_000;
const MAX_PROXY_HEADERS = 16 * 1024;

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function readArguments(values) {
  const result = new Map();
  for (let index = 0; index < values.length; index += 2) {
    const name = values[index];
    const value = values[index + 1];
    if (!name?.startsWith("--") || value == null) fail("Invalid bridge arguments.");
    result.set(name.slice(2), value);
  }
  return result;
}

function parseEndpoint(value, schemes, label) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    fail(`${label} URL is invalid.`);
  }
  if (!schemes.has(parsed.protocol) || !parsed.hostname || parsed.username || parsed.password) {
    fail(`${label} URL is invalid.`);
  }
  if ((parsed.pathname && parsed.pathname !== "/") || parsed.search || parsed.hash) {
    fail(`${label} URL may contain only scheme, host, and port.`);
  }
  return parsed;
}

function endpointPort(endpoint) {
  if (endpoint.port) return Number(endpoint.port);
  return endpoint.protocol === "https:" ? 443 : 80;
}

function trustedRoots() {
  if (typeof tls.getCACertificates !== "function") return undefined;
  const certificates = [];
  for (const type of ["default", "system"]) {
    try {
      certificates.push(...tls.getCACertificates(type));
    } catch {
      // Older supported Node builds may not expose every certificate store.
    }
  }
  return certificates.length ? [...new Set(certificates)] : undefined;
}

function authority(hostname, port) {
  const host = hostname.replace(/^\[|\]$/gu, "");
  return `${net.isIP(host) === 6 ? `[${host}]` : host}:${port}`;
}

function createConnectAgent(proxy) {
  const roots = trustedRoots();
  const agent = new https.Agent({ keepAlive: true });

  agent.createConnection = (options, callback) => {
    let settled = false;
    let proxySocket;
    const done = (error, socket) => {
      if (settled) return;
      settled = true;
      callback(error, socket);
    };
    const reject = (message) => {
      proxySocket?.destroy();
      done(new Error(message));
    };
    const targetHost = String(options.servername ?? options.hostname ?? options.host ?? "").replace(/^\[|\]$/gu, "");
    const targetPort = Number(options.port ?? 443);
    if (!targetHost || !Number.isInteger(targetPort) || targetPort < 1 || targetPort > 65_535) {
      queueMicrotask(() => done(new Error("Invalid upstream target.")));
      return undefined;
    }

    const connectOptions = { host: proxy.hostname, port: endpointPort(proxy) };
    proxySocket = proxy.protocol === "https:"
      ? tls.connect({ ...connectOptions, ...(roots ? { ca: roots } : {}), servername: proxy.hostname })
      : net.connect(connectOptions);
    const connectedEvent = proxy.protocol === "https:" ? "secureConnect" : "connect";
    const onProxyError = () => reject("Corporate proxy connection failed.");
    proxySocket.once("error", onProxyError);
    proxySocket.setTimeout(CONNECT_TIMEOUT_MS, () => reject("Corporate proxy connection timed out."));
    proxySocket.once(connectedEvent, () => {
      const target = authority(targetHost, targetPort);
      proxySocket.write([
        `CONNECT ${target} HTTP/1.1`,
        `Host: ${target}`,
        "Proxy-Connection: Keep-Alive",
        "Connection: Keep-Alive",
        "",
        "",
      ].join("\r\n"));
    });

    let response = Buffer.alloc(0);
    const onData = (chunk) => {
      response = Buffer.concat([response, chunk]);
      if (response.length > MAX_PROXY_HEADERS) {
        reject("Corporate proxy response was too large.");
        return;
      }
      const headerEnd = response.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      proxySocket.removeListener("data", onData);
      proxySocket.removeListener("error", onProxyError);
      proxySocket.setTimeout(0);
      const status = /^HTTP\/1\.[01]\s+(\d{3})(?:\s|$)/u.exec(
        response.subarray(0, headerEnd).toString("latin1").split("\r\n", 1)[0] ?? "",
      );
      if (!status || Number(status[1]) !== 200) {
        reject(`Corporate proxy rejected CONNECT with status ${status?.[1] ?? "unknown"}.`);
        return;
      }
      const remainder = response.subarray(headerEnd + 4);
      if (remainder.length) proxySocket.unshift(remainder);

      const secureSocket = tls.connect({
        socket: proxySocket,
        servername: targetHost,
        ...(roots ? { ca: roots } : {}),
      });
      secureSocket.once("error", () => {
        secureSocket.destroy();
        done(new Error("TLS verification through the corporate proxy failed."));
      });
      secureSocket.once("secureConnect", () => done(null, secureSocket));
    };
    proxySocket.on("data", onData);
    return undefined;
  };
  return agent;
}

function sanitizeHeaders(headers, keepUpgrade) {
  const result = { ...headers };
  for (const name of ["proxy-authorization", "proxy-connection", "keep-alive", "transfer-encoding"]) {
    delete result[name];
  }
  if (!keepUpgrade) {
    delete result.connection;
    delete result.upgrade;
  }
  return result;
}

function stripPrivatePrefix(url, token) {
  if (typeof url !== "string" || /^(?:https?:)?\/\//iu.test(url)) return null;
  const prefix = `/${token}/backend-api`;
  if (url !== prefix && !url.startsWith(`${prefix}/`) && !url.startsWith(`${prefix}?`)) return null;
  return url.slice(token.length + 1);
}

function writeUpgradeResponse(socket, response) {
  const lines = [`HTTP/${response.httpVersion} ${response.statusCode} ${response.statusMessage}`];
  for (let index = 0; index < response.rawHeaders.length; index += 2) {
    lines.push(`${response.rawHeaders[index]}: ${response.rawHeaders[index + 1]}`);
  }
  socket.write(`${lines.join("\r\n")}\r\n\r\n`);
}

const args = readArguments(process.argv.slice(2));
const proxy = parseEndpoint(args.get("proxy"), new Set(["http:", "https:"]), "Proxy");
const target = parseEndpoint(args.get("target"), new Set(["https:"]), "Target");
const token = args.get("token") ?? "";
const parentPid = Number(args.get("parent-pid"));
if (!/^[a-f0-9]{32}$/u.test(token) || !Number.isInteger(parentPid) || parentPid < 1) {
  fail("Invalid bridge identity.");
}

const agent = createConnectAgent(proxy);
const server = http.createServer((request, response) => {
  const upstreamPath = stripPrivatePrefix(request.url, token);
  if (!upstreamPath) {
    response.writeHead(404).end();
    return;
  }
  const upstream = https.request({
    protocol: target.protocol,
    hostname: target.hostname,
    port: endpointPort(target),
    method: request.method,
    path: upstreamPath,
    headers: { ...sanitizeHeaders(request.headers, false), host: target.host },
    agent,
  }, (upstreamResponse) => {
    response.writeHead(
      upstreamResponse.statusCode ?? 502,
      upstreamResponse.statusMessage,
      sanitizeHeaders(upstreamResponse.headers, false),
    );
    upstreamResponse.pipe(response);
  });
  upstream.setTimeout(CONNECT_TIMEOUT_MS, () => upstream.destroy(new Error("Upstream request timed out.")));
  upstream.on("error", () => {
    if (!response.headersSent) response.writeHead(502);
    response.end();
  });
  request.pipe(upstream);
});

server.on("upgrade", (request, socket, head) => {
  const upstreamPath = stripPrivatePrefix(request.url, token);
  if (!upstreamPath) {
    socket.end("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
    return;
  }
  const upstream = https.request({
    protocol: target.protocol,
    hostname: target.hostname,
    port: endpointPort(target),
    method: request.method,
    path: upstreamPath,
    headers: { ...sanitizeHeaders(request.headers, true), host: target.host },
    agent,
  });
  upstream.setTimeout(CONNECT_TIMEOUT_MS, () => upstream.destroy(new Error("Upstream upgrade timed out.")));
  upstream.on("upgrade", (upstreamResponse, upstreamSocket, upstreamHead) => {
    writeUpgradeResponse(socket, upstreamResponse);
    if (head.length) upstreamSocket.write(head);
    if (upstreamHead.length) socket.write(upstreamHead);
    socket.pipe(upstreamSocket).pipe(socket);
  });
  upstream.on("response", (upstreamResponse) => {
    writeUpgradeResponse(socket, upstreamResponse);
    upstreamResponse.pipe(socket);
  });
  upstream.on("error", () => socket.destroy());
  upstream.end();
});

server.on("clientError", (_error, socket) => socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"));
server.listen(0, "127.0.0.1", () => {
  const address = server.address();
  if (!address || typeof address === "string") fail("Bridge listener did not start.");
  process.stdout.write(`READY ${address.port}\n`);
});

const parentWatch = setInterval(() => {
  try {
    process.kill(parentPid, 0);
  } catch {
    clearInterval(parentWatch);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1_000).unref();
  }
}, 2_000);
parentWatch.unref();
