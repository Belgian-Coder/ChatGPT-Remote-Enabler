"use strict";

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  findDeviceKeyProvider,
  findDeviceKeyProviderInWindow,
  pairDelimiters,
  tokenizeJavaScript,
} = require("./device-key-provider-contract.cjs");

// Bump this when the preparation algorithm or its marker contract changes.
// Product/package versions intentionally do not participate in this identity.
const PATCH_SCHEMA = 6;
const FUSE_SENTINEL = Buffer.from("dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX", "ascii");
const ENABLE_EMBEDDED_ASAR_INTEGRITY_VALIDATION = 4;
const REMOTE_CONTROL_CLIENT_PATH = "/codex/remote/control/client";

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

function findUniqueByteOffset(contents, needle) {
  const first = contents.indexOf(needle);
  if (first < 0) return -1;
  const second = contents.indexOf(needle, first + needle.length);
  return second < 0 ? first : -2;
}

function patchFuse(file) {
  const contents = fs.readFileSync(file);
  const sentinel = findUniqueByteOffset(contents, FUSE_SENTINEL);
  if (sentinel < 0) fail(sentinel === -2
    ? "The private Electron runtime contains an ambiguous fuse marker."
    : "The private Electron runtime has no recognizable fuse marker.");
  const versionOffset = sentinel + FUSE_SENTINEL.length;
  const countOffset = versionOffset + 1;
  const valuesOffset = countOffset + 1;
  if (contents.length <= valuesOffset || contents[versionOffset] !== 1 || contents[countOffset] <= ENABLE_EMBEDDED_ASAR_INTEGRITY_VALIDATION) {
    fail("The private Electron runtime has an unsupported generic fuse layout.");
  }
  const fuseOffset = valuesOffset + ENABLE_EMBEDDED_ASAR_INTEGRITY_VALIDATION;
  if (contents[fuseOffset] === 0x30) return;
  if (contents[fuseOffset] !== 0x31) fail("The private Electron runtime has an unsupported ASAR-integrity fuse value.");
  contents[fuseOffset] = 0x30;
  fs.writeFileSync(file, contents);
}

function tokenRangeText(source, tokens, start, end) {
  if (start >= end) return "";
  return source.slice(tokens[start].start, tokens[end - 1].end);
}

function containsTokenValue(tokens, start, end, value) {
  for (let index = start; index < end; index += 1) {
    if (tokens[index].value === value) return true;
  }
  return false;
}

function findExpressionEnd(tokens, pairs, start) {
  for (let index = start; index < tokens.length; index += 1) {
    const value = tokens[index].value;
    if (pairs.has(index) && ["(", "[", "{"].includes(value)) {
      index = pairs.get(index);
      continue;
    }
    if ([",", ";", "}"].includes(value)) return index;
  }
  return tokens.length;
}

function enclosingObjectBodies(tokens, pairs, index) {
  const bodies = [];
  for (const [open, close] of pairs) {
    if (open >= close || tokens[open]?.value !== "{" || open >= index || close <= index) continue;
    bodies.push({ open, close });
  }
  bodies.sort((left, right) => (left.close - left.open) - (right.close - right.open));
  return bodies;
}

function findControllerWebSocketPatchInWindow(contents, baseOffset = 0) {
  const { source, tokens } = tokenizeJavaScript(contents);
  const pairs = pairDelimiters(tokens, { allowUnbalanced: true });
  if (!pairs) return null;
  const candidates = [];
  for (let index = 0; index < tokens.length; index += 1) {
    if (tokens[index].value !== "websocketUrl" || tokens[index + 1]?.value !== ":") continue;
    const expressionStart = index + 2;
    const expressionEnd = findExpressionEnd(tokens, pairs, expressionStart);
    if (expressionStart >= expressionEnd || !containsTokenValue(tokens, expressionStart, expressionEnd, REMOTE_CONTROL_CLIENT_PATH)) continue;
    const body = enclosingObjectBodies(tokens, pairs, index).find(candidate => {
      const required = ["envId", "connectionGroup", "connectionKey", "getAuthHeaders", "enrollClient", "authorizeDeviceKeyChallenge"];
      return required.every(name => containsTokenValue(tokens, candidate.open + 1, candidate.close, name));
    });
    if (!body) continue;
    const expression = tokenRangeText(source, tokens, expressionStart, expressionEnd);
    candidates.push({
      kind: "legacy-websocket",
      alreadyPatched: expression.includes("CHATGPT_REMOTE_WS_URL"),
      end: tokens[expressionEnd - 1].end + baseOffset,
      start: tokens[expressionStart].start + baseOffset,
      replacement: expression.includes("CHATGPT_REMOTE_WS_URL") ? null : "process.env.CHATGPT_REMOTE_WS_URL",
    });
    index = expressionEnd - 1;
  }
  // Newer controller implementations build a handshake object instead of
  // exposing a websocketUrl property. Their URL is assigned to a local before
  // being passed to the handshake result. Discover that assignment from the
  // endpoint literal and the surrounding controller capability object.
  if (candidates.length === 0) {
    for (let pathIndex = 0; pathIndex < tokens.length; pathIndex += 1) {
      if (tokens[pathIndex].type !== "string" || tokens[pathIndex].value !== REMOTE_CONTROL_CLIENT_PATH) continue;
      let assignment = null;
      for (let cursor = pathIndex - 1; cursor >= 0; cursor -= 1) {
        if ([";", "{"].includes(tokens[cursor].value)) break;
        if (tokens[cursor].value !== "=" || tokens[cursor - 1]?.type !== "identifier") continue;
        const expressionStart = cursor + 1;
        const expressionEnd = findExpressionEnd(tokens, pairs, expressionStart);
        if (expressionStart < expressionEnd &&
            containsTokenValue(tokens, expressionStart, expressionEnd, REMOTE_CONTROL_CLIENT_PATH)) {
          assignment = { expressionStart, expressionEnd };
          break;
        }
      }
      if (!assignment) continue;
      const body = enclosingObjectBodies(tokens, pairs, pathIndex).find(candidate => {
        const required = ["envId", "connectionGroup", "connectionKey", "getHandshake"];
        return required.every(name => containsTokenValue(tokens, candidate.open + 1, candidate.close, name));
      });
      if (!body) continue;
      const expression = tokenRangeText(source, tokens, assignment.expressionStart, assignment.expressionEnd);
      candidates.push({
        kind: "modern-handshake",
        alreadyPatched: expression.includes("CHATGPT_REMOTE_WS_URL"),
        end: tokens[assignment.expressionEnd - 1].end + baseOffset,
        start: tokens[assignment.expressionStart].start + baseOffset,
        replacement: expression.includes("CHATGPT_REMOTE_WS_URL") ? null : "process.env.CHATGPT_REMOTE_WS_URL",
      });
      pathIndex = assignment.expressionEnd - 1;
    }
  }
  if (candidates.length !== 1) return null;
  return candidates[0];
}

function findControllerWebSocketPatch(contents) {
  const anchor = Buffer.from(REMOTE_CONTROL_CLIENT_PATH, "utf8");
  const windowBefore = 32 * 1024;
  const windowAfter = 32 * 1024;
  const candidates = new Map();
  for (let cursor = 0; cursor < contents.length;) {
    const anchorOffset = contents.indexOf(anchor, cursor);
    if (anchorOffset < 0) break;
    const start = Math.max(0, anchorOffset - windowBefore);
    const end = Math.min(contents.length, anchorOffset + anchor.length + windowAfter);
    const candidate = findControllerWebSocketPatchInWindow(contents.subarray(start, end), start);
    if (candidate) candidates.set(`${candidate.start}:${candidate.end}`, candidate);
    cursor = anchorOffset + anchor.length;
  }
  return candidates.size === 1 ? [...candidates.values()][0] : null;
}

function findApiTargetCapabilityInWindow(contents, baseOffset = 0) {
  const { source, tokens } = tokenizeJavaScript(contents);
  const pairs = pairDelimiters(tokens, { allowUnbalanced: true });
  if (!pairs) return null;
  const candidates = [];
  for (let index = 0; index < tokens.length; index += 1) {
    if (tokens[index].value !== "CODEX_API_BASE_URL") continue;
    const body = enclosingObjectBodies(tokens, pairs, index).find(candidate => {
      const required = ["CODEX_API_ENDPOINT", "devApiBaseUrl", "prodApiBaseUrl"];
      return required.every(name => containsTokenValue(tokens, candidate.open + 1, candidate.close, name));
    });
    if (!body) continue;
    candidates.push({
      kind: "modern-api-target",
      start: tokens[body.open].start + baseOffset,
      end: tokens[body.close].end + baseOffset,
      replacement: null,
      sourceSpan: source.slice(tokens[body.open].start, tokens[body.close].end),
    });
    index = body.close;
  }
  if (candidates.length !== 1) return null;
  return candidates[0];
}

function findApiTargetCapability(contents) {
  const anchor = Buffer.from("CODEX_API_BASE_URL", "utf8");
  const candidates = new Map();
  for (let cursor = 0; cursor < contents.length;) {
    const anchorOffset = contents.indexOf(anchor, cursor);
    if (anchorOffset < 0) break;
    for (const radius of [4 * 1024, 16 * 1024, 32 * 1024]) {
      const start = Math.max(0, anchorOffset - radius);
      const end = Math.min(contents.length, anchorOffset + anchor.length + radius);
      const candidate = findApiTargetCapabilityInWindow(contents.subarray(start, end), start);
      if (candidate) {
        candidates.set(`${candidate.start}:${candidate.end}`, candidate);
        break;
      }
    }
    cursor = anchorOffset + anchor.length;
  }
  return candidates.size === 1 ? [...candidates.values()][0] : null;
}

function findValidatorFunction(tokens, pairs, bodyOpen) {
  const parameterClose = bodyOpen - 1;
  if (tokens[parameterClose]?.value === ")") {
    const parameterOpen = pairs.get(parameterClose);
    if (parameterOpen == null || parameterOpen >= parameterClose) return null;
    const functionToken = parameterOpen - 2;
    if (tokens[functionToken]?.value === "function") {
      const nameToken = tokens[functionToken + 1];
      if (!nameToken || nameToken.type !== "identifier") return null;
      return { name: nameToken.value, parameterOpen, parameterClose, start: tokens[functionToken].start };
    }
    // A minifier may emit a method (`check(a,b){...}`) or an arrow function
    // (`(a,b)=>{...}`) for the same validator capability.
    if (tokens[parameterOpen - 1]?.type === "identifier" || tokens[parameterClose + 1]?.value === "=>") {
      return { name: null, parameterOpen, parameterClose, start: tokens[parameterOpen].start };
    }
  }
  if (tokens[parameterClose]?.value === "=>") {
    if (tokens[parameterClose - 1]?.type === "identifier") {
      return { name: null, parameterOpen: parameterClose - 1, parameterClose: parameterClose - 1, start: tokens[parameterClose - 1].start };
    }
    const parameterOpen = pairs.get(parameterClose - 1);
    if (parameterOpen != null) return { name: null, parameterOpen, parameterClose: parameterClose - 1, start: tokens[parameterOpen].start };
  }
  return null;
}

function findValidatorNames(tokens, bodyOpen, bodyClose) {
  let targetName = null;
  let urlName = null;
  let urlInputName = null;
  let protocolName = null;
  for (let index = bodyOpen + 1; index < bodyClose; index += 1) {
    if (tokens[index].value === "targetOrigin" || tokens[index].value === "targetPath") {
      const candidate = tokens[index - 1]?.value === "." ? tokens[index - 2] : tokens[index - 1];
      if (candidate?.type === "identifier") targetName = targetName ?? candidate.value;
    }
    if (tokens[index].value === "new" && tokens[index + 1]?.value === "URL" && tokens[index + 2]?.value === "(") {
      const candidate = tokens[index + 3];
      if (candidate?.type === "identifier") {
        const close = tokens[index + 4]?.value === ")" ? index + 4 : null;
        if (close != null && tokens[index - 1]?.value === "=" && tokens[index - 2]?.type === "identifier") {
          urlName = tokens[index - 2].value;
          urlInputName = candidate.value;
        }
      }
    }
  }
  if (!urlName) return null;
  for (let index = bodyOpen + 1; index + 3 < bodyClose; index += 1) {
    if (tokens[index].type !== "identifier" || tokens[index + 1]?.value !== "=" ||
        tokens[index + 2]?.value !== urlName || tokens[index + 3]?.value !== "." ||
        tokens[index + 4]?.value !== "protocol") continue;
    protocolName = tokens[index].value;
    break;
  }
  if (!targetName || !protocolName) return null;
  return { protocolName, targetName, urlName, urlInputName };
}

function buildValidatorReplacement(source, tokens, validator, body, names) {
  const bodySource = source.slice(tokens[body.open].start, tokens[body.close].end);
  if (bodySource.includes("/crv.cjs")) return null;
  // Keep the function/method/arrow declaration intact. A separate verified
  // helper leaves enough room for the complete mapping and validation rules
  // without growing the minified ASAR entry.
  return `{return require(process.resourcesPath+\`/crv.cjs\`)(${names.targetName},${names.urlInputName})}`;
}

function findChallengeTargetPatchInWindow(contents, baseOffset = 0) {
  const { source, tokens } = tokenizeJavaScript(contents);
  const pairs = pairDelimiters(tokens, { allowUnbalanced: true });
  if (!pairs) return null;
  const candidates = [];
  for (let index = 0; index + 2 < tokens.length; index += 1) {
    if (tokens[index].value !== "new" || tokens[index + 1].value !== "URL" || tokens[index + 2].value !== "(") continue;
    const close = pairs.get(index + 2);
    if (close == null || close <= index + 3) continue;
    const body = enclosingObjectBodies(tokens, pairs, index).find(candidate => {
      const values = ["targetOrigin", "targetPath", "protocol", "pathname"];
      const bodySource = source.slice(tokens[candidate.open].end, tokens[candidate.close].start);
      const hasProtocolLiteral = tokens.slice(candidate.open + 1, candidate.close)
        .some(token => token.type === "string" && ["ws:", "wss:"].includes(token.value));
      const hasHostReference = containsTokenValue(tokens, candidate.open + 1, candidate.close, "host") || /\.host\b/u.test(bodySource);
      return values.every(value => containsTokenValue(tokens, candidate.open + 1, candidate.close, value)) && hasHostReference && hasProtocolLiteral;
    });
    if (!body) continue;
    const validator = findValidatorFunction(tokens, pairs, body.open);
    if (!validator) continue;
    const names = findValidatorNames(tokens, body.open, body.close);
    if (!names) continue;
    const replacement = buildValidatorReplacement(source, tokens, validator, body, names);
    candidates.push({
      alreadyPatched: replacement == null,
      end: tokens[body.close].end + baseOffset,
      kind: "legacy-challenge-validator",
      start: tokens[body.open].start + baseOffset,
      replacement,
    });
    index = close;
  }
  if (candidates.length !== 1) return null;
  return candidates[0];
}

function findChallengeTargetPatch(contents) {
  const anchors = [Buffer.from("targetPath", "utf8"), Buffer.from("targetOrigin", "utf8")];
  const windowBefore = 16 * 1024;
  const windowAfter = 16 * 1024;
  const candidates = new Map();
  for (const anchor of anchors) {
    for (let cursor = 0; cursor < contents.length;) {
      const anchorOffset = contents.indexOf(anchor, cursor);
      if (anchorOffset < 0) break;
      const start = Math.max(0, anchorOffset - windowBefore);
      const end = Math.min(contents.length, anchorOffset + anchor.length + windowAfter);
      const candidate = findChallengeTargetPatchInWindow(contents.subarray(start, end), start);
      if (candidate) candidates.set(`${candidate.start}:${candidate.end}`, candidate);
      cursor = anchorOffset + anchor.length;
    }
  }
  return candidates.size === 1 ? [...candidates.values()][0] : null;
}

function patchSpanInPlace(contents, start, end, replacement, label) {
  const originalLength = end - start;
  const replacementBytes = Buffer.from(replacement, "utf8");
  if (replacementBytes.length > originalLength) fail(`The ${label} semantic patch does not fit in place.`);
  replacementBytes.copy(contents, start);
  contents.fill(0x20, start + replacementBytes.length, end);
}

function patchDeviceKeyLoader(contents, provider = findDeviceKeyProvider(contents)) {
  if (!provider) fail("This ChatGPT build does not expose an unambiguous device-key provider capability.");
  const replacement = `${provider.requireName}(this.resourcesPath+\`/crk.cjs\`)()`;
  patchSpanInPlace(contents, provider.start, provider.end, replacement, "existing protected device-key loader");
  return provider;
}

function patchAsar(file, features) {
  const contents = fs.readFileSync(file);
  let controller = null;
  let challenge = null;
  let provider = null;
  if (features.proxyEnabled) {
    // Discover both transport selection and challenge target validation before
    // mutating any byte. Both controller layouts need the exact loopback-to-
    // public target mapping while preserving the server's signed challenge.
    controller = findControllerWebSocketPatch(contents);
    if (!controller) fail("This ChatGPT build does not expose one unambiguous Remote-control WebSocket capability.");
    challenge = findChallengeTargetPatch(contents);
    if (!challenge) fail("This ChatGPT build does not expose one unambiguous challenge/API target capability.");
  }
  if (features.legacyDeviceKeys) {
    provider = findDeviceKeyProvider(contents);
    if (!provider) fail("This ChatGPT build does not expose an unambiguous device-key provider capability.");
  }
  if (features.proxyEnabled) {
    if (controller.replacement) patchSpanInPlace(contents, controller.start, controller.end, controller.replacement, "Remote-control WebSocket");
    if (challenge.replacement) patchSpanInPlace(contents, challenge.start, challenge.end, challenge.replacement, "challenge/API target");
  }
  if (features.legacyDeviceKeys) patchDeviceKeyLoader(contents, provider);
  if (features.proxyEnabled) {
    const controllerText = contents.subarray(controller.start, controller.end).toString("utf8");
    if (!controllerText.includes("CHATGPT_REMOTE_WS_URL")) fail("The Remote-control WebSocket semantic patch did not apply.");
    if (challenge) {
      const challengeText = contents.subarray(challenge.start, challenge.end).toString("utf8");
      if (!challengeText.includes("/crv.cjs")) fail("The challenge/API target semantic patch did not apply.");
    }
  }
  if (provider) {
    const providerText = contents.subarray(provider.start, provider.end).toString("utf8");
    if (!providerText.includes("/crk.cjs")) fail("The protected device-key loader semantic patch did not apply.");
  }
  fs.writeFileSync(file, contents);
}

function isCurrent(destination, expected) {
  const markerPath = path.join(destination, ".chatgpt-remote-proxy-runtime.json");
  try {
    const marker = JSON.parse(fs.readFileSync(markerPath, "utf8"));
    return marker.patchSchema === PATCH_SCHEMA &&
      marker.proxyEnabled === expected.proxyEnabled &&
      (!expected.proxyEnabled ||
        (marker.challengeValidatorSha256 === expected.challengeValidatorSha256 &&
          sha256(path.join(destination, "resources", "crv.cjs")) === expected.challengeValidatorSha256)) &&
      marker.legacyDeviceKeys === expected.legacyDeviceKeys &&
      (!expected.legacyDeviceKeys ||
        (sha256(path.join(destination, "resources", "crk.cjs")) === expected.compatibilityLoaderSha256 &&
          sha256(path.join(destination, "resources", "crks.cjs")) === expected.compatibilityServiceSha256)) &&
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
  // This value is retained only as diagnostic marker metadata. It is not
  // validated and does not participate in runtime identity or reuse.
  const packageVersion = args.get("package-version") ?? "";
  if (!path.isAbsolute(source)) fail("The source app path is invalid.");
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
    challengeValidatorSha256: proxyEnabled ? sha256(path.join(__dirname, "remote-control-target.cjs")) : null,
    compatibilityLoaderSha256: legacyDeviceKeys ? sha256(path.join(__dirname, "legacy-device-key-compat.cjs")) : null,
    compatibilityServiceSha256: legacyDeviceKeys ? sha256(path.join(__dirname, "main-payload.js")) : null,
    sourceAppAsarSha256: sha256(sourceAsar),
    sourceChromeSha256: sha256(sourceChrome),
  };
  const compatibilityIdentity = legacyDeviceKeys
    ? `-k${expected.compatibilityLoaderSha256.slice(0, 8)}${expected.compatibilityServiceSha256.slice(0, 8)}` : "";
  const identity = `${expected.sourceAppAsarSha256.slice(0, 12)}-${expected.sourceChromeSha256.slice(0, 12)}-p${PATCH_SCHEMA}${proxyEnabled ? `-proxy-v${expected.challengeValidatorSha256.slice(0, 12)}` : ""}${compatibilityIdentity}`;
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
    if (proxyEnabled) fs.copyFileSync(path.join(__dirname, "remote-control-target.cjs"), path.join(staging, "resources", "crv.cjs"));
    if (legacyDeviceKeys) {
      fs.copyFileSync(path.join(__dirname, "legacy-device-key-compat.cjs"), path.join(staging, "resources", "crk.cjs"));
      fs.copyFileSync(path.join(__dirname, "main-payload.js"), path.join(staging, "resources", "crks.cjs"));
    }
    patchFuse(stagedChrome);
    const marker = {
      patchSchema: PATCH_SCHEMA,
      proxyEnabled,
      legacyDeviceKeys,
      challengeValidatorSha256: expected.challengeValidatorSha256,
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

function describePatch(candidate) {
  if (!candidate) return { matchCount: 0, requiredGrowth: null, span: null };
  const span = candidate.end - candidate.start;
  const requiredGrowth = candidate.replacement == null ? 0 : Buffer.byteLength(candidate.replacement, "utf8") - span;
  return {
    matchCount: 1,
    requiredGrowth,
    span: { start: candidate.start, end: candidate.end, length: span },
  };
}

function describeDeviceKeyProvider(provider) {
  if (!provider) return { matchCount: 0, requiredGrowth: null, span: null };
  const replacement = `${provider.requireName}(this.resourcesPath+\`/crk.cjs\`)()`;
  const span = provider.end - provider.start;
  return {
    matchCount: 1,
    requiredGrowth: Buffer.byteLength(replacement, "utf8") - span,
    span: { start: provider.start, end: provider.end, length: span },
  };
}

function describeCapabilities(controller, challenge, provider) {
  return {
    challengeTarget: {
      ...describePatch(challenge),
      mode: "verified-transport-target-mapping",
    },
    controllerWebSocket: describePatch(controller),
    deviceKeyProvider: describeDeviceKeyProvider(provider),
  };
}

function analyzeProxyCapabilities(contents) {
  if (!Buffer.isBuffer(contents)) throw new TypeError("Proxy capability analysis requires a Buffer.");
  const controller = findControllerWebSocketPatch(contents);
  const challenge = findChallengeTargetPatch(contents);
  const provider = findDeviceKeyProvider(contents);
  return describeCapabilities(controller, challenge, provider);
}

function scanFileAnchors(file, anchors) {
  const descriptor = fs.openSync(file, "r");
  const offsets = new Map(anchors.map(anchor => [anchor, []]));
  const maximumAnchorLength = Math.max(...anchors.map(anchor => Buffer.byteLength(anchor, "utf8")));
  const chunk = Buffer.allocUnsafe(1024 * 1024);
  let carry = Buffer.alloc(0);
  let fileOffset = 0;
  try {
    for (;;) {
      const count = fs.readSync(descriptor, chunk, 0, chunk.length, null);
      if (!count) break;
      const combined = carry.length === 0 ? chunk.subarray(0, count) : Buffer.concat([carry, chunk.subarray(0, count)]);
      const combinedBase = fileOffset - carry.length;
      for (const anchor of anchors) {
        const needle = Buffer.from(anchor, "utf8");
        const found = offsets.get(anchor);
        for (let cursor = 0;;) {
          const local = combined.indexOf(needle, cursor);
          if (local < 0) break;
          found.push(combinedBase + local);
          cursor = local + needle.length;
        }
      }
      fileOffset += count;
      carry = Buffer.from(combined.subarray(Math.max(0, combined.length - maximumAnchorLength + 1)));
    }
  } finally {
    fs.closeSync(descriptor);
  }
  return offsets;
}

function readBoundedFileWindow(file, start, end) {
  const length = end - start;
  const result = Buffer.allocUnsafe(length);
  const descriptor = fs.openSync(file, "r");
  try {
    let offset = 0;
    while (offset < length) {
      const count = fs.readSync(descriptor, result, offset, length - offset, start + offset);
      if (!count) return result.subarray(0, offset);
      offset += count;
    }
  } finally {
    fs.closeSync(descriptor);
  }
  return result;
}

function analyzeProxyFile(file) {
  const fileSize = fs.statSync(file).size;
  const anchors = scanFileAnchors(file, [
    REMOTE_CONTROL_CLIENT_PATH,
    "targetPath",
    "targetOrigin",
    "remote-control-device-key.node",
  ]);
  const controllerCandidates = new Map();
  for (const anchorOffset of anchors.get(REMOTE_CONTROL_CLIENT_PATH)) {
    const start = Math.max(0, anchorOffset - 32 * 1024);
    const end = Math.min(fileSize, anchorOffset + Buffer.byteLength(REMOTE_CONTROL_CLIENT_PATH, "utf8") + 32 * 1024);
    const candidate = findControllerWebSocketPatchInWindow(readBoundedFileWindow(file, start, end), start);
    if (candidate) controllerCandidates.set(`${candidate.start}:${candidate.end}`, candidate);
  }
  const controller = controllerCandidates.size === 1 ? [...controllerCandidates.values()][0] : null;
  const challengeCandidates = new Map();
  {
    for (const anchorName of ["targetPath", "targetOrigin"]) {
      const anchorLength = Buffer.byteLength(anchorName, "utf8");
      for (const anchorOffset of anchors.get(anchorName)) {
        const start = Math.max(0, anchorOffset - 16 * 1024);
        const end = Math.min(fileSize, anchorOffset + anchorLength + 16 * 1024);
        const candidate = findChallengeTargetPatchInWindow(readBoundedFileWindow(file, start, end), start);
        if (candidate) challengeCandidates.set(`${candidate.start}:${candidate.end}`, candidate);
      }
    }
  }
  const challenge = challengeCandidates.size === 1 ? [...challengeCandidates.values()][0] : null;
  const providerCandidates = new Map();
  const providerAnchor = "remote-control-device-key.node";
  const providerLength = Buffer.byteLength(providerAnchor, "utf8");
  for (const anchorOffset of anchors.get(providerAnchor)) {
    for (const radius of [4 * 1024, 8 * 1024, 16 * 1024, 32 * 1024]) {
      const start = Math.max(0, anchorOffset - radius);
      const end = Math.min(fileSize, anchorOffset + providerLength + radius);
      const candidate = findDeviceKeyProviderInWindow(readBoundedFileWindow(file, start, end), start);
      if (candidate) {
        providerCandidates.set(`${candidate.start}:${candidate.end}`, candidate);
        break;
      }
    }
  }
  const provider = providerCandidates.size === 1 ? [...providerCandidates.values()][0] : null;
  return describeCapabilities(controller, challenge, provider);
}

module.exports = {
  analyzeProxyCapabilities,
  analyzeProxyFile,
  findChallengeTargetPatch,
  findChallengeTargetPatchInWindow,
  findApiTargetCapability,
  findApiTargetCapabilityInWindow,
  findControllerWebSocketPatch,
  findControllerWebSocketPatchInWindow,
  findDeviceKeyProvider,
  main,
  patchAsar,
  patchDeviceKeyLoader,
  patchFuse,
};

if (require.main === module) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
}
