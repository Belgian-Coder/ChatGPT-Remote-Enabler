"use strict";
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { createCompatibilityAddon, needsLegacyDeviceKeyCompatibility } = require("../runtime/legacy-device-key-compat.cjs");
const { DeviceKeyService } = require("../runtime/main-payload.js");

function unavailableNative() {
  return {
    createDeviceKey: () => { throw Error("This fixture must not create native keys"); },
    getDeviceKeyPublic: () => { throw Object.assign(Error("Native provider does not contain this key"), { code: "NATIVE_KEY_NOT_FOUND" }); },
    signDeviceKey: () => { throw Error("Unknown native key must not be signed"); },
    deleteDeviceKey: () => { throw Error("Unknown native key must not be deleted"); },
  };
}
async function verifyExistingKey(storePath, keyId) {
  const service = new DeviceKeyService({ storePath });
  const compat = createCompatibilityAddon(unavailableNative(), () => service);
  const publicKey = await compat.getDeviceKeyPublic(keyId);
  const payload = Buffer.from("isolated-compatibility-regression", "utf8");
  const signed = await compat.signDeviceKey(keyId, payload);
  const key = crypto.createPublicKey({ key: Buffer.from(publicKey.publicKeySpkiDerBase64, "base64"), format: "der", type: "spki" });
  assert.equal(crypto.verify("sha256", payload, key, Buffer.from(signed.signatureDerBase64, "base64")), true);
  return publicKey;
}

(async () => {
  if (process.argv[2] === "--fresh-process") {
    await verifyExistingKey(process.argv[3], process.argv[4]);
    process.stdout.write("verified\n");
    return;
  }
  let legacyCalls = 0;
  const nativeCalls = [];
  const nativePublic = { keyId: "native-fixture", publicKeySpkiDerBase64: "native-public" };
  const nativeFailure = Error("native signing rejected");
  const native = {
    createDeviceKey: mode => { nativeCalls.push(["create", mode]); return nativePublic; },
    getDeviceKeyPublic: keyId => { nativeCalls.push(["public", keyId]); if (keyId !== "native-fixture") throw nativeFailure; return nativePublic; },
    signDeviceKey: () => { throw nativeFailure; },
    deleteDeviceKey: keyId => { nativeCalls.push(["delete", keyId]); },
  };
  const compat = createCompatibilityAddon(native, () => { legacyCalls++; return { getDeviceKeyPublic: () => { throw Error("No legacy key"); } }; });
  assert.equal(compat.createDeviceKey("hardware_only"), nativePublic);
  assert.equal(await compat.getDeviceKeyPublic("native-fixture"), nativePublic);
  await assert.rejects(compat.signDeviceKey("native-fixture", Buffer.from("payload")), error => error === nativeFailure);
  assert.equal(legacyCalls, 0, "native keys and native signing errors must not invoke the older provider");
  await compat.deleteDeviceKey("native-fixture");
  await assert.rejects(compat.getDeviceKeyPublic("unknown"), error => error === nativeFailure);
  assert.equal(legacyCalls, 1, "an unknown key must fail with the native error after a bounded legacy lookup");

  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "remote-key-compat-test-"));
  try {
    assert.equal(needsLegacyDeviceKeyCompatibility(temporary), false);
    if (process.platform !== "win32") {
      console.log(JSON.stringify({ nativeProviderPreserved: true, unknownKeysRejected: true, windowsDpapi: "not available on this platform" }));
      return;
    }
    const storePath = path.join(temporary, "remote-control-device-keys.windows.json");
    const service = new DeviceKeyService({ storePath });
    const publicKey = await service.createDeviceKey("allow_os_protected_nonextractable");
    const globalStatePath = path.join(temporary, ".codex-global-state.json");
    fs.writeFileSync(globalStatePath, JSON.stringify({ "electron-remote-control-client-enrollments": { fixture: publicKey } }));
    assert.equal(needsLegacyDeviceKeyCompatibility(temporary), true, "normal startup must detect a matching existing enrollment");
    fs.writeFileSync(globalStatePath, JSON.stringify({ "electron-remote-control-client-enrollments": { fixture: { ...publicKey, publicKeySpkiDerBase64: "different" } } }));
    assert.equal(needsLegacyDeviceKeyCompatibility(temporary), false, "unrelated or mismatched records must not select compatibility");
    fs.writeFileSync(globalStatePath, JSON.stringify({ "electron-remote-control-client-enrollments": { fixture: publicKey } }));
    const before = fs.readFileSync(storePath);
    assert.deepEqual(await verifyExistingKey(storePath, publicKey.keyId), publicKey);
    const childResult = execFileSync(process.execPath, [__filename, "--fresh-process", storePath, publicKey.keyId], { encoding: "utf8", windowsHide: true, timeout: 30000 });
    assert.equal(childResult.trim(), "verified", "a new process must recover and use the same protected key");
    assert.deepEqual(fs.readFileSync(storePath), before, "startup, public-key reads, and signing must not rewrite the protected store");
    const deletion = createCompatibilityAddon(unavailableNative(), () => new DeviceKeyService({ storePath }));
    await deletion.deleteDeviceKey(publicKey.keyId);
    assert.equal(needsLegacyDeviceKeyCompatibility(temporary), false, "explicit key deletion must remove only its existing store record");
    console.log(JSON.stringify({ nativeProviderPreserved: true, unknownKeysRejected: true, matchingEnrollmentSelected: true, mismatchedEnrollmentRejected: true, realWindowsDpapi: true, existingKeySigned: true, freshProcessSignedSameKey: true, protectedStorePreserved: true, explicitDeletionWorks: true }));
  } finally {
    const resolved = path.resolve(temporary);
    if (path.dirname(resolved) !== path.resolve(os.tmpdir()) || !path.basename(resolved).startsWith("remote-key-compat-test-")) throw Error("Unsafe test cleanup path");
    fs.rmSync(resolved, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
