"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "..", "renderer-mobile-project-view.js"), "utf8");
const functions = source.slice(source.indexOf("  function isSyntheticHostName("), source.indexOf("  function metadataFromNativeProject("));
let saved = {};
const context = vm.createContext({
  HOST_NAMES_KEY: "names",
  config: { localDisplayName: "Local device", hostDisplayNames: { "remote-one": "Remote desktop" } },
  readRecords: () => ({ ...saved }),
  writeRecords: (_key, value) => { saved = structuredClone(value); },
});
vm.runInContext(functions, context);
assert.equal(context.hostName("local", new Map(), null), "Local device");
assert.equal(context.hostName("remote-one", new Map(), null), "Remote desktop");
context.config.hostDisplayNames = {};
assert.equal(context.hostName("remote-one", new Map(), null), "Remote desktop", "Missing connection data must retain the remembered name");
assert.equal(context.hostName("remote-one", new Map([["remote-one", "Renamed desktop"]]), null), "Renamed desktop");
assert.equal(context.hostName("remote-one", new Map([["remote-one", "Remote env_placeholder"]]), null), "Renamed desktop", "Synthetic names must never replace a real name");
vm.runInContext(functions, context);
assert.equal(context.hostName("remote-one", new Map(), null), "Renamed desktop", "Reinstalling the renderer must reuse persisted names");
assert.equal(context.hostName("remote-two", new Map(), null), "remote-two", "Host identities must not borrow another device's name");
context.config.hostDisplayNames = { "remote-three": "" };
assert.equal(context.hostName("remote-three", new Map(), null), "remote-three", "Blank seeded names are not valid labels");
console.log("Host name persistence self-test passed.");
