"use strict";

const DEVICE_KEY_MODULE_NAME = "remote-control-device-key.node";
const DEVICE_KEY_MODULE = Buffer.from(`\`${DEVICE_KEY_MODULE_NAME}\``, "utf8");
const MINIFIED_IDENTIFIER = "[$A-Z_a-z][$\\w]*";

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

function findAuditedDeviceKeyProvider(contents) {
  if (!Buffer.isBuffer(contents) || occurrenceCount(contents, DEVICE_KEY_MODULE) !== 1) return null;
  const moduleOffset = contents.indexOf(DEVICE_KEY_MODULE);
  const windowStart = Math.max(0, moduleOffset - 512);
  const windowEnd = Math.min(contents.length, moduleOffset + 4096);
  const source = contents.subarray(windowStart, windowEnd).toString("utf8");
  const declaration = new RegExp(
    `var (?<requireName>${MINIFIED_IDENTIFIER})=\\(0,${MINIFIED_IDENTIFIER}\\.createRequire\\)\\(__filename\\),(?<moduleName>${MINIFIED_IDENTIFIER})=\`${DEVICE_KEY_MODULE_NAME.replaceAll(".", "\\.")}\``,
    "u",
  ).exec(source);
  if (!declaration?.groups) return null;
  const identity = new RegExp(
    `resourcesPath;addon=null;(?:constructor\\(${MINIFIED_IDENTIFIER}\\)\\{[^{}]*\\})?createDeviceKey\\((?<argument>${MINIFIED_IDENTIFIER})\\)\\{return this\\.getAddon\\(\\)\\.createDeviceKey\\(\\k<argument>\\?\\?\`hardware_only\`\\)\\}deleteDeviceKey\\((?<deleteArgument>${MINIFIED_IDENTIFIER})\\)\\{return this\\.getAddon\\(\\)\\.deleteDeviceKey\\(\\k<deleteArgument>\\)\\}getDeviceKeyPublic\\((?<publicArgument>${MINIFIED_IDENTIFIER})\\)\\{return this\\.getAddon\\(\\)\\.getDeviceKeyPublic\\(\\k<publicArgument>\\)\\}async signDeviceKey\\((?<signKey>${MINIFIED_IDENTIFIER}),(?<signInput>${MINIFIED_IDENTIFIER})\\)\\{let (?<signPayload>${MINIFIED_IDENTIFIER})=${MINIFIED_IDENTIFIER}\\(\\k<signInput>\\);return\\{\\.\\.\\.await this\\.getAddon\\(\\)\\.signDeviceKey\\(\\k<signKey>,\\k<signPayload>\\),signedPayloadBase64:\\k<signPayload>\\.toString\\(\`base64\`\\)\\}\\}`,
    "u",
  ).exec(source);
  if (!identity) return null;

  const loaders = [
    {
      name: "guarded-windows",
      expression: `getAddon\\(\\)\\{if\\(process\\.platform!==\`darwin\`&&process\\.platform!==\`win32\`\\)throw Error\\(\`Remote control device keys are only available on macOS and Windows\`\\);if\\(this\\.resourcesPath==null\\)throw Error\\(\`Remote control device keys require resourcesPath\`\\);(?<loader>return this\\.addon\\?\\?=(?<requireName>${MINIFIED_IDENTIFIER})\\(\\(0,${MINIFIED_IDENTIFIER}\\.join\\)\\(this\\.resourcesPath,\`native\`,(?<moduleName>${MINIFIED_IDENTIFIER})\\)\\),this\\.addon)\\}`,
    },
    {
      name: "platform-neutral-windows",
      expression: `getAddon\\(\\)\\{if\\(this\\.resourcesPath==null\\)throw Error\\(\`Remote control device keys require resourcesPath\`\\);(?<loader>return this\\.addon\\?\\?=(?<requireName>${MINIFIED_IDENTIFIER})\\(\\(0,${MINIFIED_IDENTIFIER}\\.join\\)\\(this\\.resourcesPath,\`native\`,(?<moduleName>${MINIFIED_IDENTIFIER})\\)\\),this\\.addon)\\}`,
    },
  ];
  const matches = loaders.flatMap(({ name, expression }) => {
    const match = new RegExp(expression, "u").exec(source);
    if (!match?.groups || declaration.index >= identity.index ||
        identity.index + identity[0].length !== match.index ||
        match.groups.requireName !== declaration.groups.requireName ||
        match.groups.moduleName !== declaration.groups.moduleName) return [];
    return [{ match, name }];
  });
  if (matches.length !== 1) return null;
  const [{ match, name }] = matches;
  const original = Buffer.from(match.groups.loader, "utf8");
  if (occurrenceCount(contents, original) !== 1) return null;
  return { loaderVariant: name, original, requireName: match.groups.requireName };
}

module.exports = {
  DEVICE_KEY_MODULE_NAME,
  findAuditedDeviceKeyProvider,
};
