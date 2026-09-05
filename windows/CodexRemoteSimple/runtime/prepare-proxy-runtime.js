"use strict";

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const PATCH_SCHEMA = 3;
const FUSE_SENTINEL = Buffer.from("dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX", "ascii");
const ENABLE_EMBEDDED_ASAR_INTEGRITY_VALIDATION = 4;
const ORIGINAL_CONTROLLER = Buffer.from(
  "Tle=class extends n.$t{constructor(e){let t=wC(e.desktopApiOptions),i=e.globalState,a=e.deviceKeyClient;super({envId:e.hostConfig.env_id,connectionGroup:e.appServerClient,connectionKey:t,websocketUrl:n.en(r.H(e.desktopApiOptions,`/codex/remote/control/client`)),getAuthHeaders:({headers:t}={})=>EC({appServerClient:e.appServerClient,desktopApiOptions:e.desktopApiOptions,headers:t}),enrollClient:({headers:n})=>DC({appServerClient:e.appServerClient,deviceKeyClient:a,desktopApiOptions:e.desktopApiOptions,enrollmentKey:t,globalState:i,headers:n,onEnrollmentAuthorizationRequired:e.onEnrollmentAuthorizationRequired,requestRemoteControlEnrollmentStepUpToken:e.requestRemoteControlEnrollmentStepUpToken}),authorizeDeviceKeyChallenge:e=>Yle({challenge:e,deviceKeyClient:a,enrollmentKey:t,globalState:i})})}}",
  "utf8",
);
const PATCHED_CONTROLLER = Buffer.from(
  "Tle=class extends n.$t{constructor(e){let t=e.desktopApiOptions,i=e.globalState,a=e.deviceKeyClient,o=e.appServerClient,s=wC(t);super({envId:e.hostConfig.env_id,connectionGroup:o,connectionKey:s,websocketUrl:process.env.CHATGPT_REMOTE_WS_URL??n.en(r.H(t,`/codex/remote/control/client`)),getAuthHeaders:({headers:e}={})=>EC({appServerClient:o,desktopApiOptions:t,headers:e}),enrollClient:({headers:n})=>DC({appServerClient:o,deviceKeyClient:a,desktopApiOptions:t,enrollmentKey:s,globalState:i,headers:n,onEnrollmentAuthorizationRequired:e.onEnrollmentAuthorizationRequired,requestRemoteControlEnrollmentStepUpToken:e.requestRemoteControlEnrollmentStepUpToken}),authorizeDeviceKeyChallenge:e=>Yle({challenge:e,deviceKeyClient:a,enrollmentKey:s,globalState:i})})}}",
  "utf8",
);
const ORIGINAL_CHALLENGE_TARGET_VALIDATOR = Buffer.from(
  "function vQ(e,t){let n=new URL(t),r=n.protocol===`wss:`?`https:`:n.protocol===`ws:`?`http:`:null;return r!=null&&e.targetOrigin===`${r}//${n.host}`&&e.targetPath===n.pathname}",
  "utf8",
);
const PATCHED_CHALLENGE_TARGET_VALIDATOR = Buffer.from(
  "function vQ(e,t){let n=new URL(process.env.CRWU||t),r=n.protocol===`wss:`?`https:`:`http:`;return e.targetOrigin===`${r}//${n.host}`&&e.targetPath===n.pathname}",
  "utf8",
);
const ORIGINAL_DEVICE_KEY_LOADER = Buffer.from(
  "return this.addon??=Yke((0,p.join)(this.resourcesPath,`native`,Xke)),this.addon",
  "utf8",
);
const PATCHED_DEVICE_KEY_LOADER = Buffer.from(
  "return this.addon??=Yke(this.resourcesPath+`/crk.cjs`)(),this.addon",
  "utf8",
);

function fail(message) {
  throw new Error(message);
}

function readArguments(values) {
  const result = new Map();
  for (let index = 0; index < values.length; index += 2) {
    const name = values[index];
    const value = values[index + 1];
    if (!name?.startsWith("--") || value == null) fail("Invalid proxy-runtime arguments.");
    result.set(name.slice(2), value);
  }
  return result;
}

function sha256(file) {
  const hash = crypto.createHash("sha256");
  const descriptor = fs.openSync(file, "r");
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  try {
    for (;;) {
      const count = fs.readSync(descriptor, buffer, 0, buffer.length, null);
      if (!count) break;
      hash.update(buffer.subarray(0, count));
    }
  } finally {
    fs.closeSync(descriptor);
  }
  return hash.digest("hex");
}

function occurrenceCount(buffer, needle) {
  let count = 0;
  let offset = 0;
  for (;;) {
    const index = buffer.indexOf(needle, offset);
    if (index < 0) return count;
    count += 1;
    offset = index + needle.length;
  }
}

function patchFuse(file) {
  const contents = fs.readFileSync(file);
  if (occurrenceCount(contents, FUSE_SENTINEL) !== 1) {
    fail("The private Electron runtime has an unsupported fuse signature.");
  }
  const sentinel = contents.indexOf(FUSE_SENTINEL);
  const versionOffset = sentinel + FUSE_SENTINEL.length;
  const countOffset = versionOffset + 1;
  const valuesOffset = countOffset + 1;
  if (contents[versionOffset] !== 1 || contents[countOffset] <= ENABLE_EMBEDDED_ASAR_INTEGRITY_VALIDATION) {
    fail("The private Electron runtime has an unsupported fuse layout.");
  }
  const fuseOffset = valuesOffset + ENABLE_EMBEDDED_ASAR_INTEGRITY_VALIDATION;
  if (contents[fuseOffset] !== 0x31) {
    fail("Embedded ASAR integrity validation is not enabled in the private Electron runtime.");
  }
  contents[fuseOffset] = 0x30;
  fs.writeFileSync(file, contents);
}

function patchInPlace(contents, original, replacement, label) {
  if (replacement.length > original.length) fail(`The ${label} patch does not fit in place.`);
  if (occurrenceCount(contents, original) !== 1 || occurrenceCount(contents, replacement) !== 0) {
    fail(`This ChatGPT build does not contain the audited ${label} signature.`);
  }
  const offset = contents.indexOf(original);
  replacement.copy(contents, offset);
  contents.fill(0x20, offset + replacement.length, offset + original.length);
}

function patchAsar(file, features) {
  const contents = fs.readFileSync(file);
  if (features.proxyEnabled) {
    patchInPlace(contents, ORIGINAL_CONTROLLER, PATCHED_CONTROLLER, "Remote-control controller");
    patchInPlace(
      contents,
      ORIGINAL_CHALLENGE_TARGET_VALIDATOR,
      PATCHED_CHALLENGE_TARGET_VALIDATOR,
      "Remote-control challenge target validator",
    );
  }
  if (features.legacyDeviceKeys) patchInPlace(contents, ORIGINAL_DEVICE_KEY_LOADER, PATCHED_DEVICE_KEY_LOADER, "existing protected device-key loader");
  fs.writeFileSync(file, contents);
}

function isCurrent(destination, expected) {
  const markerPath = path.join(destination, ".chatgpt-remote-proxy-runtime.json");
  try {
    const marker = JSON.parse(fs.readFileSync(markerPath, "utf8"));
    return marker.patchSchema === PATCH_SCHEMA &&
      marker.proxyEnabled === expected.proxyEnabled &&
      marker.legacyDeviceKeys === expected.legacyDeviceKeys &&
      (!expected.legacyDeviceKeys ||
        (sha256(path.join(destination, "resources", "crk.cjs")) === expected.compatibilityLoaderSha256 &&
          sha256(path.join(destination, "resources", "crks.cjs")) === expected.compatibilityServiceSha256)) &&
      marker.packageVersion === expected.packageVersion &&
      marker.sourceAppAsarSha256 === expected.sourceAppAsarSha256 &&
      marker.sourceChromeSha256 === expected.sourceChromeSha256 &&
      sha256(path.join(destination, "resources", "app.asar")) === marker.patchedAppAsarSha256 &&
      sha256(path.join(destination, "chrome.dll")) === marker.patchedChromeSha256 &&
      fs.statSync(path.join(destination, "ChatGPT.exe")).isFile();
  } catch {
    return false;
  }
}

function assertSafeDestination(destination, safeRoot) {
  const parent = path.dirname(destination);
  if (path.normalize(parent).toLowerCase() !== path.normalize(safeRoot).toLowerCase() ||
      !/^proxy-runtime-[a-z0-9._-]+$/iu.test(path.basename(destination))) {
    fail("The private runtime destination is outside its managed directory.");
  }
}

function renameWithRetry(source, destination) {
  const retryable = new Set(["EACCES", "EBUSY", "EPERM"]);
  const deadline = Date.now() + 15_000;
  for (;;) {
    try {
      fs.renameSync(source, destination);
      return;
    } catch (error) {
      if (!retryable.has(error?.code) || Date.now() >= deadline) throw error;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 250);
    }
  }
}

function main() {
  const args = readArguments(process.argv.slice(2));
  for (const option of ["proxy-enabled", "legacy-device-keys"]) {
    if (args.has(option) && !["true", "false"].includes(args.get(option))) fail(`Invalid ${option} option.`);
  }
  const proxyEnabled = args.get("proxy-enabled") !== "false";
  const legacyDeviceKeys = args.get("legacy-device-keys") === "true";
  if (!proxyEnabled && !legacyDeviceKeys) fail("A private runtime requires a compatibility feature.");
  const source = path.resolve(args.get("source-app") ?? "");
  const packageVersion = args.get("package-version") ?? "";
  if (!path.isAbsolute(source) || !/^\d+\.\d+\.\d+\.\d+$/u.test(packageVersion)) {
    fail("The source app or package version is invalid.");
  }
  const localAppData = process.env.LOCALAPPDATA;
  if (!localAppData) fail("LOCALAPPDATA is not available.");
  const safeRoot = path.resolve(localAppData, "ChatGPTRemoteEnabler", "patched-chatgpt");
  const sourceExecutable = path.join(source, "ChatGPT.exe");
  const sourceAsar = path.join(source, "resources", "app.asar");
  const sourceChrome = path.join(source, "chrome.dll");
  for (const file of [sourceExecutable, sourceAsar, sourceChrome]) {
    if (!fs.statSync(file).isFile()) fail(`The installed ChatGPT app is incomplete: ${path.basename(file)}`);
  }

  const expected = {
    packageVersion,
    proxyEnabled,
    legacyDeviceKeys,
    compatibilityLoaderSha256: legacyDeviceKeys ? sha256(path.join(__dirname, "legacy-device-key-compat.cjs")) : null,
    compatibilityServiceSha256: legacyDeviceKeys ? sha256(path.join(__dirname, "main-payload.js")) : null,
    sourceAppAsarSha256: sha256(sourceAsar),
    sourceChromeSha256: sha256(sourceChrome),
  };
  const compatibilityIdentity = legacyDeviceKeys
    ? `-k${expected.compatibilityLoaderSha256.slice(0, 8)}${expected.compatibilityServiceSha256.slice(0, 8)}` : "";
  const identity = `${packageVersion}-${expected.sourceAppAsarSha256.slice(0, 12)}-p${PATCH_SCHEMA}${proxyEnabled ? "-proxy" : ""}${compatibilityIdentity}`;
  const destination = path.join(safeRoot, `proxy-runtime-${identity}`);
  assertSafeDestination(destination, safeRoot);
  fs.mkdirSync(safeRoot, { recursive: true });

  if (isCurrent(destination, expected)) {
    process.stdout.write(`${JSON.stringify({
      reused: true,
      executablePath: path.join(destination, "ChatGPT.exe"),
      appAsarPath: path.join(destination, "resources", "app.asar"),
      runtimeRoot: destination,
    })}\n`);
    return;
  }

  const staging = `${destination}.staging-${crypto.randomUUID().replaceAll("-", "")}`;
  const retired = `${destination}.retired-${crypto.randomUUID().replaceAll("-", "")}`;
  try {
    fs.cpSync(source, staging, { recursive: true, force: false, errorOnExist: true });
    const stagedAsar = path.join(staging, "resources", "app.asar");
    const stagedChrome = path.join(staging, "chrome.dll");
    patchAsar(stagedAsar, expected);
    if (legacyDeviceKeys) {
      fs.copyFileSync(path.join(__dirname, "legacy-device-key-compat.cjs"), path.join(staging, "resources", "crk.cjs"));
      fs.copyFileSync(path.join(__dirname, "main-payload.js"), path.join(staging, "resources", "crks.cjs"));
    }
    patchFuse(stagedChrome);
    const marker = {
      patchSchema: PATCH_SCHEMA,
      proxyEnabled,
      legacyDeviceKeys,
      compatibilityLoaderSha256: expected.compatibilityLoaderSha256,
      compatibilityServiceSha256: expected.compatibilityServiceSha256,
      packageVersion,
      sourceAppAsarSha256: expected.sourceAppAsarSha256,
      sourceChromeSha256: expected.sourceChromeSha256,
      patchedAppAsarSha256: sha256(stagedAsar),
      patchedChromeSha256: sha256(stagedChrome),
      preparedAtUtc: new Date().toISOString(),
    };
    fs.writeFileSync(
      path.join(staging, ".chatgpt-remote-proxy-runtime.json"),
      `${JSON.stringify(marker, null, 2)}${os.EOL}`,
      { encoding: "utf8", flag: "wx" },
    );
    if (fs.existsSync(destination)) renameWithRetry(destination, retired);
    renameWithRetry(staging, destination);
    if (fs.existsSync(retired)) fs.rmSync(retired, { recursive: true, force: true });
  } catch (error) {
    if (fs.existsSync(staging)) fs.rmSync(staging, { recursive: true, force: true });
    if (!fs.existsSync(destination) && fs.existsSync(retired)) renameWithRetry(retired, destination);
    throw error;
  }

  process.stdout.write(`${JSON.stringify({
    reused: false,
    executablePath: path.join(destination, "ChatGPT.exe"),
    appAsarPath: path.join(destination, "resources", "app.asar"),
    runtimeRoot: destination,
  })}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
}
