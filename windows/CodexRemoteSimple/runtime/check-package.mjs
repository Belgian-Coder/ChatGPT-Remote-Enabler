#!/usr/bin/env node

import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { access, readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import providerContract from "./device-key-provider-contract.cjs";

const { findAuditedDeviceKeyProvider } = providerContract;

const signatures = new Map([
  ["invertedGate", Buffer.from("782640499")],
  ["deviceKeyModuleReference", Buffer.from("remote-control-device-key.node")],
  ["deviceKeySigningDomain", Buffer.from("codex-device-key-sign-payload/v1")],
  ["deviceKeyResourcesContract", Buffer.from("Remote control device keys require resourcesPath")],
  ["macOnlyGuard", Buffer.from("Remote control device keys are only available on macOS")],
  ["nativeWindowsGuard", Buffer.from("Remote control device keys are only available on macOS and Windows")],
  ["windowsControllerUi", Buffer.from("Control other devices from this PC")],
]);

const providerWindowBytes = 16 * 1024;

function createProductionAdapters() {
  return {
    access,
    createHash,
    createReadStream,
    joinPath: path.join,
    process,
    readFile,
    readdir,
    resolvePath: path.resolve,
  };
}

export async function inspectPackage(asarPath, nativeDirectory, Adapters = createProductionAdapters()) {
  const hash = Adapters.createHash("sha256");
  const signatureState = Object.fromEntries([...signatures.keys()].map((name) => [name, false]));
  const signatureCounts = Object.fromEntries([...signatures.keys()].map((name) => [name, 0]));
  const longest = Math.max(...[...signatures.values()].map((needle) => needle.length));
  let carry = Buffer.alloc(0);
  let providerCarry = Buffer.alloc(0);
  let provider = null;

  for await (const chunk of Adapters.createReadStream(asarPath, { highWaterMark: 4 * 1024 * 1024 })) {
    hash.update(chunk);
    const searchable = carry.length === 0 ? chunk : Buffer.concat([carry, chunk]);
    for (const [name, needle] of signatures) {
      let cursor = 0;
      while (cursor <= searchable.length - needle.length) {
        const index = searchable.indexOf(needle, cursor);
        if (index === -1) break;
        if (index + needle.length > carry.length) signatureCounts[name] += 1;
        cursor = index + needle.length;
      }
      signatureState[name] = signatureCounts[name] > 0;
    }
    carry = searchable.subarray(Math.max(0, searchable.length - longest + 1));

    if (!provider) {
      const providerSearchable = providerCarry.length === 0 ? chunk : Buffer.concat([providerCarry, chunk]);
      provider = findAuditedDeviceKeyProvider(providerSearchable);
      providerCarry = providerSearchable.subarray(Math.max(0, providerSearchable.length - providerWindowBytes));
    }
  }

  const nativeModule = await inspectNativeDeviceKeyModule(nativeDirectory, Adapters);
  const commonSignatures = signatureState.invertedGate
    && signatureState.deviceKeyModuleReference
    && signatureState.windowsControllerUi;
  const exactProviderSignatures = signatureCounts.deviceKeyModuleReference === 1
    && signatureCounts.deviceKeySigningDomain === 1
    && signatureCounts.deviceKeyResourcesContract === 1;
  const guardedNativeWindows = signatureCounts.nativeWindowsGuard === 1
    // The mac-only text is an exact prefix of the guarded Windows message.
    && signatureCounts.macOnlyGuard === 1
    && provider?.loaderVariant === "guarded-windows";
  const platformNeutralNativeWindows = !signatureState.macOnlyGuard
    && !signatureState.nativeWindowsGuard
    && provider?.loaderVariant === "platform-neutral-windows";
  const nativeWindows = commonSignatures
    && exactProviderSignatures
    && (guardedNativeWindows || platformNeutralNativeWindows)
    && nativeModule.format === "windows-pe";
  const legacyMainShim = commonSignatures
    && signatureState.macOnlyGuard
    && !signatureState.nativeWindowsGuard
    && !provider;
  const classification = nativeWindows
    ? "NativeWindowsCompatible"
    : legacyMainShim ? "CandidateCompatible" : nativeModule.present ? "NativeModulePresent" : "UnknownOrIncompatible";
  return {
    affected: classification === "CandidateCompatible" || classification === "NativeWindowsCompatible",
    appAsarSha256: hash.digest("hex"),
    bridgeMode: nativeWindows ? "native-renderer" : legacyMainShim ? "legacy-main-shim" : null,
    classification,
    nativeModuleFormat: nativeModule.format,
    nativeModulePresent: nativeModule.present,
    providerContract: provider !== null,
    schemaVersion: 2,
    signatureCounts,
    signatures: signatureState,
  };
}

async function inspectNativeDeviceKeyModule(directory, Adapters) {
  const pending = [directory];
  while (pending.length > 0) {
    const current = pending.pop();
    let entries;
    try {
      entries = await Adapters.readdir(current, { withFileTypes: true });
    } catch (error) {
      if (error?.code === "ENOENT" && current === directory) return { format: null, present: false };
      throw error;
    }

    for (const entry of entries) {
      const fullPath = Adapters.joinPath(current, entry.name);
      if (entry.isDirectory()) pending.push(fullPath);
      if (entry.isFile() && entry.name === "remote-control-device-key.node") {
        const header = await Adapters.readFile(fullPath);
        return {
          format: header.length >= 2 && header[0] === 0x4d && header[1] === 0x5a ? "windows-pe" : "non-windows",
          present: true,
        };
      }
    }
  }
  return { format: null, present: false };
}

export async function runCheckPackageCli(Adapters = createProductionAdapters()) {
  const [asarPath, nativeDirectory] = Adapters.process.argv.slice(2);
  if (!asarPath || !nativeDirectory) {
    Adapters.process.stderr.write("Usage: node check-package.mjs <app.asar> <native-directory>\n");
    return 2;
  }

  try {
    await Adapters.access(asarPath);
    const result = await inspectPackage(asarPath, nativeDirectory, Adapters);
    Adapters.process.stdout.write(JSON.stringify({ asarPath, nativeDirectory, ...result }));
    return 0;
  } catch (error) {
    Adapters.process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    return 1;
  }
}

const cliAdapters = createProductionAdapters();
if (cliAdapters.process.argv[1] && cliAdapters.resolvePath(cliAdapters.process.argv[1]) === fileURLToPath(import.meta.url)) {
  cliAdapters.process.exitCode = await runCheckPackageCli(cliAdapters);
}
