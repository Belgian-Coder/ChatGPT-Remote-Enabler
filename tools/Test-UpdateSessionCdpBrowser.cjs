"use strict";

// Optional real-browser integration suite. Supply Playwright through NODE_PATH
// and, when required, CHATGPT_REMOTE_BROWSER with a Chromium executable path.
// The production transport and CDP implementation are used; the adapter below
// substitutes this fixture's HTTP URL for Electron's app://-/index.html URL.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const path = require("node:path");
const { chromium } = require("playwright");
const cdp = require("../windows/CodexRemoteSimple/runtime/lib/cdp.js");
const {
  BINDING_NAME,
  CdpTransport,
  TARGET_URL,
} = require("../windows/CodexRemoteMobileProject/update-session-cdp.js");

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve(server.address().port);
    });
  });
}

function closeServer(server) {
  return new Promise((resolve) => server.close(resolve));
}

async function reservePort() {
  const server = net.createServer();
  const port = await listen(server);
  await closeServer(server);
  return port;
}

async function waitFor(predicate, message, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (!await predicate()) {
    if (Date.now() >= deadline) throw new Error(message);
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

function fixtureCdp(actualUrl, rawClients, callLog) {
  const replaceTargetUrl = (source) => source.replaceAll(JSON.stringify(TARGET_URL), JSON.stringify(actualUrl));
  return {
    async discoverTargets(port, timeoutMs) {
      return (await cdp.discoverTargets(port, timeoutMs)).map((target) => (
        target.type === "page" && target.url === actualUrl ? { ...target, url: TARGET_URL } : target
      ));
    },
    async connectTarget(target, port, timeoutMs) {
      const raw = await cdp.connectTarget(target, port, timeoutMs);
      rawClients.push(raw);
      return {
        call: async (method, params, callTimeoutMs) => {
          callLog.push({ method, params, timeoutMs: callTimeoutMs });
          if (method === "Runtime.evaluate") {
            return raw.call(method, { ...params, expression: replaceTargetUrl(params.expression) }, callTimeoutMs);
          }
          if (method === "Page.addScriptToEvaluateOnNewDocument") {
            return raw.call(method, { ...params, source: replaceTargetUrl(params.source) }, callTimeoutMs);
          }
          const result = await raw.call(method, params, callTimeoutMs);
          if (method === "Page.getFrameTree" && result?.frameTree?.frame?.url === actualUrl) {
            result.frameTree.frame.url = TARGET_URL;
          }
          return result;
        },
        close: () => raw.close(),
        onClose: (handler) => raw.onClose(handler),
        onEvent: (handler) => raw.onEvent((method, params) => {
          if (method === "Page.frameNavigated" && params?.frame?.url === actualUrl) {
            handler(method, { ...params, frame: { ...params.frame, url: TARGET_URL } });
            return;
          }
          handler(method, params);
        }),
      };
    },
  };
}

async function main() {
  const htmlServer = http.createServer((_request, response) => {
    response.writeHead(200, { "Content-Type": "text/html", "Cache-Control": "no-store" });
    response.end("<!doctype html><html><body><h1>Update session CDP fixture</h1></body></html>");
  });
  const htmlPort = await listen(htmlServer);
  const actualUrl = `http://127.0.0.1:${htmlPort}/index.html`;
  const debuggerPort = await reservePort();
  const defaultEdge = process.platform === "win32"
    ? path.join(process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)", "Microsoft", "Edge", "Application", "msedge.exe")
    : null;
  const executablePath = process.env.CHATGPT_REMOTE_BROWSER
    || (defaultEdge && fs.existsSync(defaultEdge) ? defaultEdge : undefined);
  const browser = await chromium.launch({
    executablePath,
    headless: true,
    args: [`--remote-debugging-port=${debuggerPort}`],
  });
  const rawClients = [];
  const callLog = [];
  const requests = [];
  let releasePendingRequest;
  let pendingRequestStarted = false;
  const transport = new CdpTransport(
    { rendererPort: debuggerPort },
    "real-browser-fixture-nonce",
    fixtureCdp(actualUrl, rawClients, callLog),
    { timeoutMs: 5_000 },
  );
  try {
    const page = await browser.newPage();
    await page.goto(actualUrl);
    transport.onRequest(async (action, id) => {
      requests.push({ action, id });
      if (action === "queue") {
        pendingRequestStarted = true;
        await new Promise((resolve) => { releasePendingRequest = resolve; });
      }
      return { state: "current", version: "v-real", message: null, canQueue: false, canCancel: false };
    });
    await transport.attach();
    await transport.publish({ state: "available", version: "v-real", message: "ready", canQueue: true });

    const reply = await page.evaluate(() => globalThis.__CHATGPT_REMOTE_UPDATE__.request("check"));
    assert.equal(reply.state, "current");
    assert.equal(requests.length, 1);
    assert.equal(requests[0].action, "check");
    assert.match(requests[0].id, /^[A-Za-z0-9._:-]{1,128}$/u);

    await page.evaluate(() => {
      globalThis.__activityCalls = 0;
      globalThis.__CODEX_REMOTE_MOBILE_PROJECT_VIEW__ = {
        async updateActivity() {
          globalThis.__activityCalls += 1;
          await new Promise((resolve) => setTimeout(resolve, 50));
          return { known: true, busy: true, reason: "real browser busy" };
        },
      };
    });
    const activityOne = transport.queryActivity();
    const activityTwo = transport.queryActivity();
    assert.deepEqual(await activityOne, { known: true, busy: true, reason: "real browser busy" });
    assert.deepEqual(await activityTwo, { known: true, busy: true, reason: "real browser busy" });
    assert.equal(await page.evaluate(() => globalThis.__activityCalls), 1);
    const activityCall = callLog.find((call) => call.method === "Runtime.evaluate" && call.params.expression.includes("updateActivity"));
    assert.ok(activityCall.timeoutMs >= 35_000);

    await page.reload();
    await waitFor(
      async () => page.evaluate(() => globalThis.__CHATGPT_REMOTE_UPDATE__?.getStatus?.().version === "v-real").catch(() => false),
      "The last status did not converge after a real browser reload.",
    );

    rawClients.at(-1).close();
    await waitFor(() => rawClients.length >= 2, "The real CDP socket did not reattach.");
    await waitFor(
      async () => page.evaluate(() => globalThis.__CHATGPT_REMOTE_UPDATE__?.getStatus?.().state === "available").catch(() => false),
      "The status did not converge after a real CDP reconnect.",
    );
    const replyAfterReconnect = await page.evaluate(() => globalThis.__CHATGPT_REMOTE_UPDATE__.request("check"));
    assert.equal(replyAfterReconnect.state, "current");

    const pending = page.evaluate(() => globalThis.__CHATGPT_REMOTE_UPDATE__.request("queue")
      .then(() => ({ resolved: true }), (error) => ({ resolved: false, error: error.message })));
    await waitFor(() => pendingRequestStarted, "The pending renderer request did not reach the host.");
    transport.setClosingExpected(true);
    await transport.close();
    const disposed = await pending;
    assert.equal(disposed.resolved, false);
    assert.match(disposed.error, /stopped/u);
    releasePendingRequest();

    await page.reload();
    assert.equal(await page.evaluate(() => globalThis.__CHATGPT_REMOTE_UPDATE__), undefined);
    console.log(JSON.stringify({
      realChromium: true,
      realCdpBindingRoundTrip: true,
      rendererRequestTimeoutFloorMs: 30_000,
      activityTimeoutFloorMs: activityCall.timeoutMs,
      activityCoalesced: true,
      reloadConvergence: true,
      socketReattach: true,
      disposeRejectedPending: true,
      persistentCleanup: true,
      bindingName: BINDING_NAME,
    }));
  } finally {
    releasePendingRequest?.();
    await transport.close().catch(() => {});
    await browser.close();
    await closeServer(htmlServer);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
