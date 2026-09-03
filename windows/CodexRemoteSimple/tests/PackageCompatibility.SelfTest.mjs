import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { inspectPackage } from "../runtime/check-package.mjs";

const root = await mkdtemp(path.join(os.tmpdir(), "codexremote-package-test-"));
try {
  const nativeDirectory = path.join(root, "native");
  await mkdir(nativeDirectory);
  await writeFile(path.join(nativeDirectory, "remote-control-device-key.node"), Buffer.from([0x4d, 0x5a, 0x00, 0x00]));

  const common = "782640499 remote-control-device-key.node Control other devices from this PC ";
  const nativeAsar = path.join(root, "native.asar");
  await writeFile(nativeAsar, `${common}Remote control device keys are only available on macOS and Windows`);
  const native = await inspectPackage(nativeAsar, nativeDirectory);
  assert.equal(native.schemaVersion, 2);
  assert.equal(native.classification, "NativeWindowsCompatible");
  assert.equal(native.bridgeMode, "native-renderer");
  assert.equal(native.nativeModuleFormat, "windows-pe");
  assert.equal(native.signatures.macOnlyGuard, true, "the old substring remains present in the new message");
  assert.equal(native.signatures.nativeWindowsGuard, true);

  const legacyAsar = path.join(root, "legacy.asar");
  await writeFile(legacyAsar, `${common}Remote control device keys are only available on macOS`);
  const legacy = await inspectPackage(legacyAsar, nativeDirectory);
  assert.equal(legacy.classification, "CandidateCompatible");
  assert.equal(legacy.bridgeMode, "legacy-main-shim");
  assert.equal(legacy.signatures.nativeWindowsGuard, false);

  const unknownAsar = path.join(root, "unknown.asar");
  await writeFile(unknownAsar, "unrelated package");
  const unknown = await inspectPackage(unknownAsar, nativeDirectory);
  assert.equal(unknown.affected, false);
  assert.equal(unknown.bridgeMode, null);

  process.stdout.write(`${JSON.stringify({ legacy: legacy.bridgeMode, native: native.bridgeMode, ok: true })}\n`);
} finally {
  await rm(root, { force: true, recursive: true });
}
