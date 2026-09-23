"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");
const matches = require("../runtime/remote-control-target.cjs");
const { patchAsar, analyzeProxyCapabilities } = require("../runtime/prepare-proxy-runtime.js");

const publicUrl = "wss://example.test/backend-api/codex/remote/control/client";
const bridgeUrl = `ws://127.0.0.1:43210/${"a".repeat(32)}/backend-api/codex/remote/control/client`;
const environment = { CRWU: publicUrl, CHATGPT_REMOTE_WS_URL: bridgeUrl };
const challenge = { targetOrigin: "https://example.test", targetPath: "/backend-api/codex/remote/control/client", token: "unchanged" };
const before = JSON.stringify(challenge);

assert.equal(matches(challenge, bridgeUrl, environment), true);
assert.equal(matches(challenge, publicUrl, environment), true);
assert.equal(matches({ ...challenge, targetOrigin: "https://other.test" }, bridgeUrl, environment), false);
assert.equal(matches({ ...challenge, targetPath: "/other" }, bridgeUrl, environment), false);
assert.equal(matches(challenge, bridgeUrl.replace(":43210", ":43211"), environment), false);
assert.equal(matches(challenge, bridgeUrl.replace("a".repeat(32), "b".repeat(32)), environment), false);
assert.equal(matches(challenge, publicUrl.replace("example.test", "other.test"), environment), false);
for (const publicTarget of [undefined, "garbage", publicUrl.replace("wss:", "ws:"), publicUrl + "?other=1", publicUrl.replace("example.test", "user:pass@example.test"), publicUrl + "/other"]) {
  assert.equal(matches(challenge, bridgeUrl, { ...environment, CRWU: publicTarget }), false);
}
for (const localTarget of [bridgeUrl.replace("127.0.0.1", "example.test"), bridgeUrl.replace("ws:", "wss:"), bridgeUrl + "?other=1", bridgeUrl.replace("a".repeat(32), "not-a-token")]) {
  assert.equal(matches(challenge, localTarget, { ...environment, CHATGPT_REMOTE_WS_URL: localTarget }), false);
}
assert.equal(matches(challenge, "ftp://example.test/backend-api/codex/remote/control/client", {}), false);
assert.equal(matches({ targetOrigin: "http://example.test", targetPath: "/direct" }, "ws://example.test/direct", {}), true);
assert.equal(JSON.stringify(challenge), before, "signed challenge must remain unmodified");

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "proxy-challenge-target-"));
const validatorBody = "{let z=new URL(u),q=z.protocol===`wss:`?`https:`:z.protocol===`ws:`?`http:`:null;return q!=null&&t.targetOrigin===`${q}//${z.host}`&&t.targetPath===z.pathname}";
try {
  for (const kind of ["legacy", "modern"]) {
    const controller = kind === "legacy"
      ? "const C={envId:e,connectionGroup:g,connectionKey:k,getAuthHeaders:c,enrollClient:b,authorizeDeviceKeyChallenge:a,websocketUrl:mk(k,`/codex/remote/control/client`)};"
      : "const C={envId:e,connectionGroup:g,connectionKey:k,getHandshake(){let u=mk(k,`/codex/remote/control/client`);return{url:u}}};";
    for (const declaration of ["function check(t,u)", "const check=(t,u)=>"]) {
      const file = path.join(temp, "fixture.js");
      const source = controller + declaration + validatorBody + ";globalThis.check=check;";
      fs.writeFileSync(file, source);
      assert.equal(analyzeProxyCapabilities(Buffer.from(source)).challengeTarget.matchCount, 1);
      patchAsar(file, { proxyEnabled: true, legacyDeviceKeys: false });
      assert.equal(fs.statSync(file).size, Buffer.byteLength(source), "ASAR offsets must not move");
      const sandbox = { URL, e: 0, g: 0, k: 0, c: 0, b: 0, a: 0,
        process: { resourcesPath: temp, env: environment },
        require: (requested) => {
          assert.equal(requested, temp + "/crv.cjs");
          return (value, url) => matches(value, url, environment);
        } };
      vm.runInNewContext(fs.readFileSync(file, "utf8"), sandbox);
      assert.equal(sandbox.check(challenge, bridgeUrl), true, `${kind} proxy challenge must authenticate`);
      assert.equal(sandbox.check({ ...challenge, targetOrigin: "https://other.test" }, bridgeUrl), false);
      assert.equal(sandbox.check(challenge, publicUrl), true, "direct target verification must retain its semantics");
    }
    const file = path.join(temp, "missing.js");
    fs.writeFileSync(file, controller);
    assert.throws(() => patchAsar(file, { proxyEnabled: true }), /challenge\/API target/u);
    assert.equal(fs.readFileSync(file, "utf8"), controller, "incomplete discovery must leave source untouched");
  }
  console.log(JSON.stringify({ publicChallengeThroughBridge: true, exactBridgeOnly: true, wrongOriginAndPathRejected: true, directChecksPreserved: true, signedDataUnchanged: true, legacyAndModernExecutable: true, namedAndArrowDeclarationsPreserved: true, missingValidatorRejected: true }));
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
