"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { JsonRpcWebSocket, discoverTargets } = require("../runtime/lib/cdp.js");

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

async function testAbortedDiscoveryRejects() {
  const server = http.createServer((_request, response) => {
    response.writeHead(200, { "Content-Type": "application/json" });
    response.write("[");
    setTimeout(() => response.destroy(), 10);
  });
  const port = await listen(server);
  const startedAt = Date.now();
  try {
    await assert.rejects(
      discoverTargets(port, 200),
      (error) => error?.code === "DISCOVERY_ABORTED" || error?.code === "DISCOVERY_RESPONSE_FAILED",
    );
    assert.ok(Date.now() - startedAt < 1000, "aborted discovery exceeded its deadline");
  } finally {
    await close(server);
  }
}

async function testDiscoveryUsesAbsoluteDeadline() {
  const server = http.createServer((_request, response) => {
    response.writeHead(200, { "Content-Type": "application/json" });
    response.write("[");
    const interval = setInterval(() => response.write(" "), 10);
    response.once("close", () => clearInterval(interval));
  });
  const port = await listen(server);
  const startedAt = Date.now();
  try {
    await assert.rejects(discoverTargets(port, 80), (error) => error?.code === "DISCOVERY_TIMEOUT");
    const elapsed = Date.now() - startedAt;
    assert.ok(elapsed >= 50 && elapsed < 1000, `absolute discovery deadline was not enforced: ${elapsed} ms`);
  } finally {
    await close(server);
  }
}

async function testProtocolMetadataAndEvents() {
  const client = new JsonRpcWebSocket("ws://127.0.0.1/unused");
  const events = [];
  const unsubscribe = client.onEvent((method, params) => events.push({ method, params }));
  client._onMessage(JSON.stringify({ method: "Runtime.bindingCalled", params: { name: "test", payload: "{}" } }));
  unsubscribe();
  client._onMessage(JSON.stringify({ method: "Runtime.bindingCalled", params: { name: "ignored" } }));
  assert.deepEqual(events, [{ method: "Runtime.bindingCalled", params: { name: "test", payload: "{}" } }]);

  const rejection = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("protocol response was not delivered")), 1000);
    client.pending.set(7, {
      method: "Runtime.evaluate",
      reject: (error) => {
        clearTimeout(timer);
        resolve(error);
      },
      resolve: reject,
      timer,
    });
  });
  client._onMessage(JSON.stringify({ id: 7, error: { code: -32000, message: "Execution context was destroyed." } }));
  const error = await rejection;
  assert.equal(error.code, "CDP_PROTOCOL_ERROR");
  assert.equal(error.protocolCode, -32000);

  const closeOrder = [];
  let closeCalls = 0;
  client.pending.set(8, {
    method: "Runtime.evaluate",
    reject: (closeError) => closeOrder.push(`pending:${closeError.code}`),
    resolve: () => {},
    timer: setTimeout(() => {}, 1000),
  });
  client.onClose((closeError) => {
    closeCalls += 1;
    assert.equal(client.pending.size, 0);
    closeOrder.push(`close:${closeError.code}`);
  });
  client._onClose();
  client._onClose();
  assert.equal(closeCalls, 1);
  assert.deepEqual(closeOrder, ["pending:WEBSOCKET_CLOSED", "close:WEBSOCKET_CLOSED"]);
}

async function main() {
  const windowsSource = fs.readFileSync(path.join(__dirname, "..", "runtime", "lib", "cdp.js"));
  const macSource = fs.readFileSync(path.join(__dirname, "..", "..", "..", "macos", "runtime", "lib", "cdp.js"));
  assert.deepEqual(macSource, windowsSource, "Windows and macOS CDP transports diverged");
  await testAbortedDiscoveryRejects();
  await testDiscoveryUsesAbsoluteDeadline();
  await testProtocolMetadataAndEvents();
  process.stdout.write(`${JSON.stringify({ absoluteDeadline: true, abortedResponse: true, bindingEvents: true, closeEvents: true, parity: true, protocolMetadata: true })}\n`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
