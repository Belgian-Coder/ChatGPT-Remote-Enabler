"use strict";

// Preserve an existing Remote Enabler enrollment when Codex gains its own
// Windows key provider. No enrollment, key creation, or network request occurs
// here. New keys continue to use the native provider.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

function codexHome() {
  const configured = process.env.CODEX_HOME?.trim();
  return configured ? path.resolve(configured) : path.join(os.homedir(), ".codex");
}

function needsLegacyDeviceKeyCompatibility(home = codexHome()) {
  try {
    const globalState = JSON.parse(fs.readFileSync(path.join(home, ".codex-global-state.json"), "utf8"));
    const stored = JSON.parse(fs.readFileSync(path.join(home, "remote-control-device-keys.windows.json"), "utf8"));
    const keys = stored.schemaVersion === 1 ? stored.keys : stored;
    if (!keys || typeof keys !== "object" || Array.isArray(keys)) return false;
    const enrollments = globalState["electron-remote-control-client-enrollments"];
    if (!enrollments || typeof enrollments !== "object" || Array.isArray(enrollments)) return false;
    return Object.values(enrollments).some(enrollment => {
      if (!enrollment || typeof enrollment.keyId !== "string") return false;
      const key = Object.hasOwn(keys, enrollment.keyId) ? keys[enrollment.keyId] : null;
      return key?.algorithm === enrollment.algorithm
        && key?.protectionClass === "os_protected_nonextractable"
        && key.protectionClass === enrollment.protectionClass
        && typeof key.encryptedPrivateKeyBase64 === "string" && key.encryptedPrivateKeyBase64.length > 0
        && typeof key.publicKeySpkiDerBase64 === "string" && key.publicKeySpkiDerBase64.length > 0
        && key.publicKeySpkiDerBase64 === enrollment.publicKeySpkiDerBase64;
    });
  } catch { return false; }
}

function createCompatibilityAddon(nativeAddon, getLegacyService) {
  for (const method of ["createDeviceKey", "getDeviceKeyPublic", "signDeviceKey", "deleteDeviceKey"]) {
    if (typeof nativeAddon?.[method] !== "function") throw new Error("The native device-key provider is incomplete.");
  }
  async function providerFor(keyId) {
    try {
      return { provider: nativeAddon, publicKey: await nativeAddon.getDeviceKeyPublic(keyId) };
    } catch (nativeError) {
      try {
        const legacy = getLegacyService();
        return { provider: legacy, publicKey: await legacy.getDeviceKeyPublic(keyId) };
      } catch { throw nativeError; }
    }
  }
  return Object.freeze({
    createDeviceKey: (...args) => nativeAddon.createDeviceKey(...args),
    getDeviceKeyPublic: async keyId => (await providerFor(keyId)).publicKey,
    signDeviceKey: async (keyId, payload) => (await providerFor(keyId)).provider.signDeviceKey(keyId, payload),
    deleteDeviceKey: async keyId => (await providerFor(keyId)).provider.deleteDeviceKey(keyId),
  });
}

function loadCompatibilityAddon(resourcesPath = __dirname) {
  const nativeAddon = require(path.join(resourcesPath, "native", "remote-control-device-key.node"));
  let legacy;
  return createCompatibilityAddon(nativeAddon, () => {
    if (!legacy) {
      const { DeviceKeyService } = require(path.join(resourcesPath, "crks.cjs"));
      legacy = new DeviceKeyService();
    }
    return legacy;
  });
}

module.exports = Object.assign(loadCompatibilityAddon, { createCompatibilityAddon, needsLegacyDeviceKeyCompatibility });
if (require.main === module) {
  if (process.argv.length !== 3 || process.argv[2] !== "--check") {
    process.stderr.write("Usage: node legacy-device-key-compat.cjs --check\n");
    process.exitCode = 2;
  } else {
    process.stdout.write(JSON.stringify({ legacyDeviceKeyCompatibilityNeeded: needsLegacyDeviceKeyCompatibility() }) + "\n");
  }
}
