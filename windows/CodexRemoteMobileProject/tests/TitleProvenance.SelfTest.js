"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const originalSource = fs.readFileSync(rendererPath, "utf8");
const testSource = originalSource
  .replace("(() => {", "globalThis.__titleTest = (() => {")
  .replace(
    "  return install();\n})();",
    "  return { mergeTaskTitle, parseInventoryPayload, parsedThreadTitle, persistedThreadTitle, publishedThreadTitle, state, taskFromThread, threadTitle, trustedThreadTitle };\n})();",
  );

const rows = [];
const context = vm.createContext({
  TextDecoder,
  TextEncoder,
  clearInterval,
  clearTimeout,
  console,
  crypto: { randomUUID: () => "title-test" },
  document: {
    querySelectorAll: () => rows,
  },
  globalThis: null,
  localStorage: {
    getItem: () => null,
    removeItem: () => {},
    setItem: () => {},
  },
  setInterval,
  setTimeout,
});
context.globalThis = context;
vm.runInContext(testSource, context, { filename: rendererPath });
const title = context.__titleTest;

function payload(thread, publisherVersion) {
  return {
    generatedAt: new Date().toISOString(),
    projects: [],
    ...(publisherVersion === undefined ? {} : { publisherVersion }),
    schemaVersion: 1,
    threads: [thread],
  };
}

function parsedThread(thread, publisherVersion) {
  return title.parseInventoryPayload(payload(thread, publisherVersion)).threads[0];
}

assert.deepEqual(
  JSON.parse(JSON.stringify(title.persistedThreadTitle({ preview: "private prompt text" }))),
  { titleSource: "none" },
);

const legacy = parsedThread({ id: "legacy", preview: "private prompt", title: "laundered legacy title" });
assert.equal(legacy.title, undefined);
assert.equal(Object.hasOwn(legacy, "titleSource"), false);
assert.equal(title.taskFromThread(legacy, "remote").title, "Untitled task");

const oldAnnotated = parsedThread({ id: "old", title: "old trusted-looking title", titleSource: "app-server-name" }, 52);
assert.equal(oldAnnotated.title, undefined);
assert.equal(oldAnnotated.titleSource, "app-server-name");

for (const titleSource of ["preview", "unknown-source"]) {
  const untrusted = parsedThread({ id: titleSource, title: "private prompt", titleSource }, 53);
  assert.equal(untrusted.title, undefined);
  assert.equal(untrusted.titleSource, titleSource);
  assert.equal(title.taskFromThread(untrusted, "remote").title, "Untitled task");
}

const trusted = parsedThread({ id: "trusted", title: "Persisted title", titleSource: "app-server-name" }, 53);
assert.equal(trusted.title, "Persisted title");
assert.equal(trusted.titleSource, "app-server-name");

const gossiped = title.parseInventoryPayload({
  ...payload({ id: "direct", title: "Direct title", titleSource: "native-title" }, 53),
  peers: {
    "peer-host": payload({ id: "peer", title: "must not survive", titleSource: "preview" }, 50),
  },
}, true).peers.get("peer-host");
assert.equal(gossiped.publisherVersion, 50);
assert.equal(gossiped.threads[0].title, undefined);
assert.equal(gossiped.threads[0].titleSource, "preview");

title.state.threadManagers.set("local", {
  getThreadSummaries: () => [{ generatedTitle: "Generated native title", id: "native" }],
});
assert.deepEqual(
  JSON.parse(JSON.stringify(title.publishedThreadTitle({ name: "Persisted fallback", preview: "private" }, "native"))),
  { title: "Generated native title", titleSource: "native-generated-title" },
);

title.state.threadManagers.clear();
rows.push({
  getAttribute: (name) => name.endsWith("thread-id") ? "dom" : name.endsWith("thread-title") ? "Mounted native title" : null,
});
assert.deepEqual(
  JSON.parse(JSON.stringify(title.publishedThreadTitle({ name: "Persisted fallback", preview: "private" }, "dom"))),
  { title: "Mounted native title", titleSource: "native-dom" },
);
assert.deepEqual(
  JSON.parse(JSON.stringify(title.publishedThreadTitle({ name: "Persisted fallback", preview: "private" }, "persisted"))),
  { title: "Persisted fallback", titleSource: "app-server-name" },
);
assert.deepEqual(
  JSON.parse(JSON.stringify(title.publishedThreadTitle({ preview: "private prompt" }, "untitled"))),
  { titleSource: "none" },
);

const merged = { title: "Mounted title", titleSource: "native-dom" };
title.mergeTaskTitle(merged, { title: "Persisted title", titleSource: "app-server-title" });
assert.equal(merged.title, "Persisted title");
assert.equal(merged.titleSource, "app-server-title");
title.mergeTaskTitle(merged, { title: "private prompt", titleSource: "preview" });
assert.equal(merged.title, "Persisted title");

const untrustedOnly = { title: "private prompt", titleSource: "preview" };
title.mergeTaskTitle(untrustedOnly, { title: "private prompt", titleSource: "unknown-source" });
assert.equal(untrustedOnly.title, "Untitled task");
assert.equal(untrustedOnly.titleSource, "none");

assert.match(originalSource, /publisherVersion: PUBLISHER_VERSION, schemaVersion: 1/);
assert.match(originalSource, /publisherVersion: inventory\.publisherVersion/);
assert.match(originalSource, /title: thread\.title \?\? null, titleSource: thread\.titleSource/);
assert.match(originalSource, /USER_VISIBLE_THREAD_SOURCE_KINDS = Object\.freeze\(\["cli", "vscode"\]\)/);
assert.match(originalSource, /listAllRuntimeThreads\(runtime\.requestClient, false/);

console.log("Title provenance self-test passed.");
