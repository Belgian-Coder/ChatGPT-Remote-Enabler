"use strict";

// The desktop package is minified, and its local names and member order are
// implementation details. Keep discovery deliberately small and lexical: it
// recognises the device-key capability and returns the exact loader expression
// that can be replaced in place. It does not depend on a product version, a
// minifier's choice of identifiers, or a particular member order.
const DEVICE_KEY_MODULE_NAME = "remote-control-device-key.node";

const OPENERS = new Set(["(", "[", "{"]);
const CLOSERS = new Map([["}", "{"], ["]", "["], [")", "("]]);
const MULTI_PUNCTUATION = [
  ">>>=", "===", "!==", "**=", "&&=", "||=", "??=", "...", "=>", "==", "!=", "<=", ">=", "++", "--", "&&", "||", "??", "?.", "**", "<<", ">>",
];

function decodeLiteral(raw) {
  if (typeof raw !== "string" || raw.length < 2) return null;
  const quote = raw[0];
  if (!["'", '"', "`"].includes(quote) || raw[raw.length - 1] !== quote) return null;
  let value = raw.slice(1, -1);
  value = value.replace(/\\(u\{[0-9a-fA-F]+\}|u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|.)/gu, (match, escape) => {
    if (escape.startsWith("u{")) return String.fromCodePoint(Number.parseInt(escape.slice(2, -1), 16));
    if (escape.startsWith("u")) return String.fromCharCode(Number.parseInt(escape.slice(1), 16));
    if (escape.startsWith("x")) return String.fromCharCode(Number.parseInt(escape.slice(1), 16));
    return ({ n: "\n", r: "\r", t: "\t", b: "\b", f: "\f", v: "\v", "0": "\0" })[escape] ?? escape;
  });
  return value;
}

function isIdentifierStart(character) {
  return /[$A-Z_a-z]/u.test(character);
}

function isIdentifierPart(character) {
  return /[$\w]/u.test(character);
}

function tokenizeJavaScript(input) {
  const source = Buffer.isBuffer(input) ? input.toString("utf8") : String(input ?? "");
  const tokens = [];
  let index = 0;
  while (index < source.length) {
    const character = source[index];
    if (/\s/u.test(character)) {
      index += 1;
      continue;
    }
    if (character === "/" && source[index + 1] === "/") {
      index += 2;
      while (index < source.length && source[index] !== "\n" && source[index] !== "\r") index += 1;
      continue;
    }
    if (character === "/" && source[index + 1] === "*") {
      const end = source.indexOf("*/", index + 2);
      index = end < 0 ? source.length : end + 2;
      continue;
    }
    if (["'", '"', "`"].includes(character)) {
      const start = index;
      const quote = character;
      index += 1;
      while (index < source.length) {
        if (source[index] === "\\") {
          index += 2;
          continue;
        }
        if (source[index] === quote) {
          index += 1;
          break;
        }
        index += 1;
      }
      const raw = source.slice(start, index);
      tokens.push({ type: "string", value: decodeLiteral(raw), raw, start, end: index });
      continue;
    }
    if (isIdentifierStart(character)) {
      const start = index;
      index += 1;
      while (index < source.length && isIdentifierPart(source[index])) index += 1;
      tokens.push({ type: "identifier", value: source.slice(start, index), start, end: index });
      continue;
    }
    if (/[0-9]/u.test(character)) {
      const start = index;
      index += 1;
      while (index < source.length && /[0-9A-Za-z_.]/u.test(source[index])) index += 1;
      tokens.push({ type: "number", value: source.slice(start, index), start, end: index });
      continue;
    }
    const punctuation = MULTI_PUNCTUATION.find(candidate => source.startsWith(candidate, index));
    if (punctuation) {
      tokens.push({ type: "punctuation", value: punctuation, start: index, end: index + punctuation.length });
      index += punctuation.length;
      continue;
    }
    tokens.push({ type: "punctuation", value: character, start: index, end: index + 1 });
    index += 1;
  }
  return { source, tokens };
}

function pairDelimiters(tokens, { allowUnbalanced = false } = {}) {
  const stack = [];
  const pairs = new Map();
  for (let index = 0; index < tokens.length; index += 1) {
    const value = tokens[index].value;
    if (OPENERS.has(value)) {
      stack.push(index);
      continue;
    }
    const opener = CLOSERS.get(value);
    if (!opener) continue;
    if (stack.length === 0 || tokens[stack[stack.length - 1]].value !== opener) {
      if (allowUnbalanced) continue;
      return null;
    }
    const start = stack.pop();
    pairs.set(start, index);
    pairs.set(index, start);
  }
  return allowUnbalanced || stack.length === 0 ? pairs : null;
}

function isToken(token, value, type) {
  return token?.value === value && (!type || token.type === type);
}

function containsValue(tokens, start, end, value) {
  for (let index = start; index < end; index += 1) {
    if (tokens[index].type === "identifier" && tokens[index].value === value) return true;
  }
  return false;
}

function moduleLiteral(token) {
  return token?.type === "string" && typeof token.value === "string" &&
    (token.value === DEVICE_KEY_MODULE_NAME || token.value.endsWith(`/${DEVICE_KEY_MODULE_NAME}`) || token.value.endsWith(`\\${DEVICE_KEY_MODULE_NAME}`));
}

function findCreateRequireBindings(tokens, pairs) {
  const bindings = new Set();
  for (let index = 0; index < tokens.length; index += 1) {
    if (!isToken(tokens[index], "createRequire", "identifier")) continue;
    let open = index + 1;
    if (isToken(tokens[open], ")")) open += 1;
    if (!isToken(tokens[open], "(") || pairs.get(open) == null) continue;
    const close = pairs.get(open);
    if (!containsValue(tokens, open + 1, close, "__filename")) continue;
    let boundary = index - 1;
    while (boundary >= 0 && ![";", "{", "}"].includes(tokens[boundary].value)) boundary -= 1;
    for (let cursor = index - 1; cursor > boundary; cursor -= 1) {
      if (!isToken(tokens[cursor], "=", "punctuation")) continue;
      for (let candidate = cursor - 1; candidate > boundary; candidate -= 1) {
        if (tokens[candidate].type === "identifier") {
          bindings.add(tokens[candidate].value);
          break;
        }
        if ([",", ";", "{"].includes(tokens[candidate].value)) break;
      }
      break;
    }
  }
  return bindings;
}

function findModuleBindings(tokens) {
  const bindings = new Set();
  const moduleTokenIndexes = [];
  for (let index = 0; index < tokens.length; index += 1) {
    if (!moduleLiteral(tokens[index])) continue;
    moduleTokenIndexes.push(index);
    if (tokens[index - 2]?.type === "identifier" && isToken(tokens[index - 1], "=")) bindings.add(tokens[index - 2].value);
  }
  return { bindings, moduleTokenIndexes };
}

function findMethodCandidates(tokens, pairs, name, start = 0, end = tokens.length) {
  const methods = [];
  for (let index = start; index < end; index += 1) {
    if (!isToken(tokens[index], name, "identifier") || isToken(tokens[index - 1], ".")) continue;
    const open = index + 1;
    if (!isToken(tokens[open], "(") || pairs.get(open) == null) continue;
    const parameterEnd = pairs.get(open);
    const bodyOpen = parameterEnd + 1;
    if (!isToken(tokens[bodyOpen], "{") || pairs.get(bodyOpen) == null) continue;
    const bodyClose = pairs.get(bodyOpen);
    methods.push({ index, bodyOpen, bodyClose });
    index = bodyClose;
  }
  return methods;
}

function hasDelegatingCall(tokens, start, end, name) {
  for (let index = start; index + 6 < end; index += 1) {
    if (isToken(tokens[index], "this", "identifier") && isToken(tokens[index + 1], ".") &&
        isToken(tokens[index + 2], "getAddon", "identifier") && isToken(tokens[index + 3], "(") &&
        isToken(tokens[index + 4], ")") && isToken(tokens[index + 5], ".") &&
        isToken(tokens[index + 6], name, "identifier")) return true;
  }
  return false;
}

function findLoaderCalls(tokens, pairs, requireBindings, moduleBindings, moduleTokenIndexes, start, end) {
  const calls = [];
  for (let index = start; index < end; index += 1) {
    const token = tokens[index];
    if (token.type !== "identifier" || !requireBindings.has(token.value) || !isToken(tokens[index + 1], "(") || pairs.get(index + 1) == null) continue;
    const close = pairs.get(index + 1);
    let hasResourcesPath = false;
    let hasNativeDirectory = false;
    let hasModuleReference = false;
    for (let cursor = index + 2; cursor < close; cursor += 1) {
      if (isToken(tokens[cursor], "resourcesPath", "identifier")) hasResourcesPath = true;
      if (tokens[cursor].type === "string" && tokens[cursor].value === "native") hasNativeDirectory = true;
      if (moduleBindings.has(tokens[cursor].value) || moduleTokenIndexes.includes(cursor)) hasModuleReference = true;
    }
    if (!hasResourcesPath || !hasNativeDirectory || !hasModuleReference) continue;
    calls.push({ start: token.start, end: tokens[close].end, requireName: token.value });
    index = close;
  }
  return calls;
}

function findDeviceKeyProviderInWindow(contents, baseOffset = 0) {
  if (!Buffer.isBuffer(contents)) return null;
  const { source, tokens } = tokenizeJavaScript(contents);
  const pairs = pairDelimiters(tokens, { allowUnbalanced: true });
  if (!pairs) return null;
  const requireBindings = findCreateRequireBindings(tokens, pairs);
  const { bindings: moduleBindings, moduleTokenIndexes } = findModuleBindings(tokens);
  if (requireBindings.size === 0 || moduleTokenIndexes.length === 0) return null;

  const getAddonMethods = findMethodCandidates(tokens, pairs, "getAddon");
  const candidates = [];
  for (const getAddon of getAddonMethods) {
    const loaders = findLoaderCalls(tokens, pairs, requireBindings, moduleBindings, moduleTokenIndexes, getAddon.bodyOpen, getAddon.bodyClose);
    if (loaders.length !== 1) continue;
    const containingBodies = [];
    for (const [open, close] of pairs) {
      if (open >= close || tokens[open]?.value !== "{" || open >= getAddon.bodyOpen || close <= getAddon.bodyClose) continue;
      const required = ["createDeviceKey", "deleteDeviceKey", "getDeviceKeyPublic", "signDeviceKey"];
      if (!required.every(name => findMethodCandidates(tokens, pairs, name, open + 1, close).some(method =>
        method.bodyOpen > open && method.bodyClose < close && hasDelegatingCall(tokens, method.bodyOpen + 1, method.bodyClose, name)))) continue;
      if (!containsValue(tokens, open + 1, close, "resourcesPath")) continue;
      containingBodies.push({ open, close });
    }
    if (containingBodies.length === 0) continue;
    containingBodies.sort((left, right) => (left.close - left.open) - (right.close - right.open));
    const body = containingBodies[0];
    candidates.push({
      ...loaders[0],
      start: loaders[0].start + baseOffset,
      end: loaders[0].end + baseOffset,
      providerStart: tokens[body.open].start + baseOffset,
      providerEnd: tokens[body.close].end + baseOffset,
      original: Buffer.from(source.slice(loaders[0].start, loaders[0].end), "utf8"),
    });
  }
  if (candidates.length !== 1) return null;
  return candidates[0];
}

function findDeviceKeyProvider(contents) {
  if (!Buffer.isBuffer(contents)) return null;
  const anchor = Buffer.from(DEVICE_KEY_MODULE_NAME, "utf8");
  const candidates = new Map();
  for (let cursor = 0; cursor < contents.length;) {
    const anchorOffset = contents.indexOf(anchor, cursor);
    if (anchorOffset < 0) break;
    let candidate = null;
    for (const radius of [4 * 1024, 8 * 1024, 16 * 1024, 32 * 1024]) {
      const start = Math.max(0, anchorOffset - radius);
      const end = Math.min(contents.length, anchorOffset + anchor.length + radius);
      candidate = findDeviceKeyProviderInWindow(contents.subarray(start, end), start);
      if (candidate) break;
    }
    if (candidate) candidates.set(`${candidate.start}:${candidate.end}`, candidate);
    cursor = anchorOffset + anchor.length;
  }
  return candidates.size === 1 ? [...candidates.values()][0] : null;
}

module.exports = {
  DEVICE_KEY_MODULE_NAME,
  findCreateRequireBindings,
  findDeviceKeyProvider,
  findDeviceKeyProviderInWindow,
  findLoaderCalls,
  hasDelegatingCall,
  findMethodCandidates,
  findModuleBindings,
  pairDelimiters,
  tokenizeJavaScript,
};
