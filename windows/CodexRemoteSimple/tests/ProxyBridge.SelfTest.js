"use strict";

const assert = require("node:assert/strict");
const net = require("node:net");
const { createConnectAgent, stripPrivatePrefix } = require("../runtime/api-proxy-bridge.js");

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

async function testTlsHandshakeDeadline() {
  const sockets = new Set();
  const proxy = net.createServer((socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
    socket.on("error", () => {});
    socket.once("data", () => socket.write("HTTP/1.1 200 Connection Established\r\n\r\n"));
  });
  const port = await listen(proxy);
  const agent = createConnectAgent(new URL(`http://127.0.0.1:${port}`), 100);
  const startedAt = Date.now();
  try {
    const error = await new Promise((resolve, reject) => {
      const watchdog = setTimeout(() => reject(new Error("proxy TLS handshake did not honor its deadline")), 1000);
      agent.createConnection({ host: "chatgpt.com", port: 443, servername: "chatgpt.com" }, (connectionError, socket) => {
        clearTimeout(watchdog);
        socket?.destroy();
        resolve(connectionError);
      });
    });
    const elapsed = Date.now() - startedAt;
    assert.match(error?.message ?? "", /tunnel timed out/u);
    assert.ok(elapsed >= 60 && elapsed < 1000, `proxy TLS deadline was not bounded: ${elapsed} ms`);
  } finally {
    agent.destroy();
    for (const socket of sockets) socket.destroy();
    await close(proxy);
  }
}

async function main() {
  const token = "0123456789abcdef0123456789abcdef";
  assert.equal(stripPrivatePrefix(`/${token}/backend-api/test?q=1`, token), "/backend-api/test?q=1");
  assert.equal(stripPrivatePrefix(`/wrong/backend-api/test`, token), null);
  await testTlsHandshakeDeadline();
  process.stdout.write(`${JSON.stringify({ pathBoundary: true, tlsHandshakeDeadline: true })}\n`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
