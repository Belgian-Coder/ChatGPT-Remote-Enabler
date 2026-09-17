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

  const common = "782640499 Control other devices from this PC ";
  const platformNeutralProvider = "var Xke=(0,F.createRequire)(__filename),Zke=`remote-control-device-key.node`,Qke=`codex-device-key-sign-payload/v1`;$ke=class{resourcesPath;addon=null;constructor(e){this.resourcesPath=e}createDeviceKey(e){return this.getAddon().createDeviceKey(e??`hardware_only`)}deleteDeviceKey(e){return this.getAddon().deleteDeviceKey(e)}getDeviceKeyPublic(e){return this.getAddon().getDeviceKeyPublic(e)}async signDeviceKey(e,t){let n=eAe(t);return{...await this.getAddon().signDeviceKey(e,n),signedPayloadBase64:n.toString(`base64`)}}getAddon(){if(this.resourcesPath==null)throw Error(`Remote control device keys require resourcesPath`);return this.addon??=Xke((0,p.join)(this.resourcesPath,`native`,Zke)),this.addon}}";
  const guardedProvider = platformNeutralProvider.replace(
    "getAddon(){if(this.resourcesPath",
    "getAddon(){if(process.platform!==`darwin`&&process.platform!==`win32`)throw Error(`Remote control device keys are only available on macOS and Windows`);if(this.resourcesPath",
  );
  const nativeAsar = path.join(root, "native.asar");
  await writeFile(nativeAsar, `${common}${guardedProvider}`);
  const native = await inspectPackage(nativeAsar, nativeDirectory);
  assert.equal(native.schemaVersion, 2);
  assert.equal(native.classification, "NativeWindowsCompatible");
  assert.equal(native.bridgeMode, "native-renderer");
  assert.equal(native.nativeModuleFormat, "windows-pe");
  assert.equal(native.signatures.macOnlyGuard, true, "the old substring remains present in the new message");
  assert.equal(native.signatures.nativeWindowsGuard, true);
  assert.equal(native.providerContract, true);

  const platformNeutralAsar = path.join(root, "platform-neutral.asar");
  await writeFile(platformNeutralAsar, `${common}${platformNeutralProvider}`);
  const platformNeutral = await inspectPackage(platformNeutralAsar, nativeDirectory);
  assert.equal(platformNeutral.classification, "NativeWindowsCompatible");
  assert.equal(platformNeutral.bridgeMode, "native-renderer");
  assert.equal(platformNeutral.signatures.macOnlyGuard, false);
  assert.equal(platformNeutral.signatures.nativeWindowsGuard, false);
  assert.equal(platformNeutral.providerContract, true);
  assert.equal(platformNeutral.signatureCounts.deviceKeyModuleReference, 1);

  const legacyAsar = path.join(root, "legacy.asar");
  await writeFile(legacyAsar, `${common}remote-control-device-key.node Remote control device keys are only available on macOS`);
  const legacy = await inspectPackage(legacyAsar, nativeDirectory);
  assert.equal(legacy.classification, "CandidateCompatible");
  assert.equal(legacy.bridgeMode, "legacy-main-shim");
  assert.equal(legacy.signatures.nativeWindowsGuard, false);

  for (const [name, incompleteContract] of [
    ["missing-signing-domain", platformNeutralProvider.replace("codex-device-key-sign-payload/v1", "")],
    ["missing-resources-contract", platformNeutralProvider.replace("Remote control device keys require resourcesPath", "unrelated error")],
    ["empty-methods", platformNeutralProvider.replace("return this.getAddon().createDeviceKey(e??`hardware_only`)", "")],
    ["mismatched-loader", platformNeutralProvider.replace("=Xke((0,p.join)", "=Rke((0,p.join)")],
  ]) {
    const incompletePlatformNeutralAsar = path.join(root, `${name}.asar`);
    await writeFile(incompletePlatformNeutralAsar, `782640499 Control other devices from this PC ${incompleteContract}`);
    const incompletePlatformNeutral = await inspectPackage(incompletePlatformNeutralAsar, nativeDirectory);
    assert.equal(incompletePlatformNeutral.classification, "NativeModulePresent");
    assert.equal(incompletePlatformNeutral.affected, false);
    assert.equal(incompletePlatformNeutral.bridgeMode, null);
  }

  for (const [name, malformedGuardedContract] of [
    ["guarded-missing-resources", guardedProvider.replace("Remote control device keys require resourcesPath", "unrelated error")],
    ["guarded-empty-method", guardedProvider.replace("return this.getAddon().getDeviceKeyPublic(e)", "")],
    ["guarded-mismatched-loader", guardedProvider.replace("=Xke((0,p.join)", "=Rke((0,p.join)")],
  ]) {
    const malformedGuardedAsar = path.join(root, `${name}.asar`);
    await writeFile(malformedGuardedAsar, `${common}${malformedGuardedContract}`);
    const malformedGuarded = await inspectPackage(malformedGuardedAsar, nativeDirectory);
    assert.equal(malformedGuarded.classification, "NativeModulePresent");
    assert.equal(malformedGuarded.affected, false);
  }

  const guardedDecoyAsar = path.join(root, "guarded-decoy.asar");
  await writeFile(guardedDecoyAsar, `${common}remote-control-device-key.node codex-device-key-sign-payload/v1 Remote control device keys require resourcesPath Remote control device keys are only available on macOS and Windows`);
  const guardedDecoy = await inspectPackage(guardedDecoyAsar, nativeDirectory);
  assert.equal(guardedDecoy.classification, "NativeModulePresent");
  assert.equal(guardedDecoy.affected, false);
  assert.equal(guardedDecoy.providerContract, false);

  const mixedGenerationAsar = path.join(root, "mixed-generation.asar");
  await writeFile(mixedGenerationAsar, `${common}${guardedProvider} Remote control device keys are only available on macOS and Windows`);
  const mixedGeneration = await inspectPackage(mixedGenerationAsar, nativeDirectory);
  assert.equal(mixedGeneration.classification, "NativeModulePresent");
  assert.equal(mixedGeneration.affected, false);

  const duplicateContractAsar = path.join(root, "duplicate-contract.asar");
  await writeFile(duplicateContractAsar, `${common}${platformNeutralProvider} codex-device-key-sign-payload/v1`);
  const duplicateContract = await inspectPackage(duplicateContractAsar, nativeDirectory);
  assert.equal(duplicateContract.classification, "NativeModulePresent");
  assert.equal(duplicateContract.affected, false);

  const ambiguousAsar = path.join(root, "ambiguous.asar");
  await writeFile(ambiguousAsar, `${common}${platformNeutralProvider}Remote control device keys are only available on macOS`);
  const ambiguous = await inspectPackage(ambiguousAsar, nativeDirectory);
  assert.equal(ambiguous.classification, "NativeModulePresent");
  assert.equal(ambiguous.affected, false);

  const nonWindowsNativeDirectory = path.join(root, "native-non-windows");
  await mkdir(nonWindowsNativeDirectory);
  await writeFile(path.join(nonWindowsNativeDirectory, "remote-control-device-key.node"), Buffer.from([0x7f, 0x45, 0x4c, 0x46]));
  const nonWindowsNative = await inspectPackage(platformNeutralAsar, nonWindowsNativeDirectory);
  assert.equal(nonWindowsNative.classification, "NativeModulePresent");
  assert.equal(nonWindowsNative.affected, false);

  const decoyAsar = path.join(root, "decoy.asar");
  await writeFile(decoyAsar, `${common}remote-control-device-key.node codex-device-key-sign-payload/v1 Remote control device keys require resourcesPath createDeviceKey( deleteDeviceKey( getDeviceKeyPublic( signDeviceKey(`);
  const decoy = await inspectPackage(decoyAsar, nativeDirectory);
  assert.equal(decoy.classification, "NativeModulePresent");
  assert.equal(decoy.affected, false);
  assert.equal(decoy.providerContract, false);

  const unknownAsar = path.join(root, "unknown.asar");
  await writeFile(unknownAsar, "unrelated package");
  const unknown = await inspectPackage(unknownAsar, nativeDirectory);
  assert.equal(unknown.affected, false);
  assert.equal(unknown.bridgeMode, null);

  process.stdout.write(`${JSON.stringify({ legacy: legacy.bridgeMode, native: native.bridgeMode, platformNeutral: platformNeutral.bridgeMode, ok: true })}\n`);
} finally {
  await rm(root, { force: true, recursive: true });
}
