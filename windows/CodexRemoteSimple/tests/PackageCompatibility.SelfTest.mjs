import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { inspectPackage } from "../runtime/check-package.mjs";

const root = await mkdtemp(path.join(os.tmpdir(), "codexremote-package-test-"));
try {
  const asarPath = path.join(root, "app.asar");
  // The artifact can contain arbitrary renamed/minified product source. The
  // capability probe must not inspect product strings or consume the archive.
  await writeFile(asarPath, "renamed identifiers; reordered members; no stable UI text");

  const nativeDirectory = path.join(root, "native");
  await mkdir(nativeDirectory);
  await writeFile(path.join(nativeDirectory, "remote-control-device-key.node"), Buffer.from([0x4d, 0x5a, 0x00, 0x00]));
  const native = await inspectPackage(asarPath, nativeDirectory);
  assert.deepEqual(native, {
    artifactReadable: true,
    classification: "CapabilityCompatible",
    nativeModuleFormat: "windows-pe",
    nativeModulePresent: true,
    recommendedBridgeMode: "native-renderer",
    schemaVersion: 3,
  });
  assert.equal(Object.hasOwn(native, "appAsarSha256"), false);
  assert.equal(Object.hasOwn(native, "affected"), false);
  assert.equal(Object.hasOwn(native, "signatures"), false);

  const nonWindowsDirectory = path.join(root, "native-non-windows");
  await mkdir(nonWindowsDirectory);
  await writeFile(path.join(nonWindowsDirectory, "remote-control-device-key.node"), Buffer.from([0x7f, 0x45, 0x4c, 0x46]));
  const nonWindows = await inspectPackage(asarPath, nonWindowsDirectory);
  assert.equal(nonWindows.nativeModulePresent, true);
  assert.equal(nonWindows.nativeModuleFormat, "non-windows");
  assert.equal(nonWindows.recommendedBridgeMode, "legacy-main-shim");

  const absentNative = await inspectPackage(asarPath, path.join(root, "missing-native"));
  assert.deepEqual(absentNative, {
    artifactReadable: true,
    classification: "CapabilityCompatible",
    nativeModuleFormat: null,
    nativeModulePresent: false,
    recommendedBridgeMode: "legacy-main-shim",
    schemaVersion: 3,
  });

  let accessCount = 0;
  let streamCount = 0;
  const boundedAdapters = {
    access: async () => { accessCount += 1; },
    createReadStream: () => { streamCount += 1; throw new Error("full ASAR stream consumption is forbidden"); },
    joinPath: path.join,
    open: async () => ({
      read: async (buffer, offset, length) => {
        assert.equal(length, 2);
        buffer[offset] = 0x4d;
        buffer[offset + 1] = 0x5a;
        return { bytesRead: 2, buffer };
      },
      close: async () => {},
    }),
    readdir: async () => [{
      name: "remote-control-device-key.node",
      isDirectory: () => false,
      isFile: () => true,
    }],
  };
  const bounded = await inspectPackage(asarPath, nativeDirectory, boundedAdapters);
  assert.equal(bounded.artifactReadable, true);
  assert.equal(bounded.recommendedBridgeMode, "native-renderer");
  assert.equal(accessCount, 1);
  assert.equal(streamCount, 0);

  await assert.rejects(() => inspectPackage(path.join(root, "missing.asar"), nativeDirectory));
  process.stdout.write(`${JSON.stringify({ schemaVersion: native.schemaVersion, native: native.recommendedBridgeMode, legacy: absentNative.recommendedBridgeMode, boundedRead: true, ok: true })}\n`);
} finally {
  await rm(root, { force: true, recursive: true });
}
