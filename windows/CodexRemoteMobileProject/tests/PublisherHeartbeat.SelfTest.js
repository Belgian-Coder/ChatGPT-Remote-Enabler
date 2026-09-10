"use strict";

const assert = require("node:assert/strict");
const { TARGET_URL, parseArgs, pulse } = require("../publisher-heartbeat.js");

(async () => {
  assert.deepEqual(parseArgs(["--port", "1234", "--parent-pid", "5678", "--interval-ms", "9000"]), {
    intervalMs: 9000, lockPath: null, parentPid: 5678, port: 1234,
  });
  assert.throws(() => parseArgs(["--port", "0", "--parent-pid", "1"]), /renderer port/u);

  let closed = false;
  let expression = null;
  const client = { close() { closed = true; } };
  const cdp = {
    async connectTarget(target, port) {
      assert.equal(target.url, TARGET_URL);
      assert.equal(port, 1234);
      return client;
    },
    async discoverTargets() {
      return [{ type: "page", url: "app://-/other.html" }, { type: "page", url: TARGET_URL }];
    },
    async evaluate(actualClient, source) {
      assert.equal(actualClient, client);
      expression = source;
      return true;
    },
  };
  assert.equal(await pulse(1234, cdp), true);
  assert.match(expression, /publishInventoryHeartbeat/u);
  assert.equal(closed, true);
  await assert.rejects(pulse(1234, {
    async discoverTargets() { return [{ type: "page", url: TARGET_URL }, { type: "webview", url: TARGET_URL }]; },
  }), /found 2/u);
  console.log("Publisher heartbeat self-test passed.");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
