#!/usr/bin/env node

import { access, open, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

function createProductionAdapters() {
  return {
    access,
    joinPath: path.join,
    open,
    process,
    readdir,
    resolvePath: path.resolve,
  };
}

// This check intentionally reports only artifact capabilities. The package's
// product version and minified source are not compatibility identities.
export async function inspectPackage(asarPath, nativeDirectory, Adapters = createProductionAdapters()) {
  // access() is intentionally the only package-artifact operation here. A
  // prelaunch compatibility probe must remain O(1) in app.asar size; the
  // private preparer owns bounded source discovery and private-copy hashes.
  await Adapters.access(asarPath);
  const nativeModule = await inspectNativeDeviceKeyModule(nativeDirectory, Adapters);
  const nativeWindowsModule = nativeModule.present && nativeModule.format === "windows-pe";
  return {
    artifactReadable: true,
    classification: "CapabilityCompatible",
    nativeModuleFormat: nativeModule.format,
    nativeModulePresent: nativeModule.present,
    recommendedBridgeMode: nativeWindowsModule ? "native-renderer" : "legacy-main-shim",
    schemaVersion: 3,
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
        const descriptor = await Adapters.open(fullPath, "r");
        const header = Buffer.alloc(2);
        try {
          await descriptor.read(header, 0, header.length, 0);
        } finally {
          await descriptor.close();
        }
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
