"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const rendererPath = path.join(__dirname, "../renderer-mobile-project-view.js");
const source = fs.readFileSync(rendererPath, "utf8").replace(/\r\n/gu, "\n");
const testSource = source.replace("  return installWhenDocumentReady(api, state, install, probe);\n})();", "  globalThis.search = { filterLoadedGroups, loadedSearchIndex, normalizeSearch, normalizedLoadedSearchText };\n})();");
assert.notEqual(source, testSource);
const context = vm.createContext({
  TextDecoder, TextEncoder, clearInterval, clearTimeout, console,
  crypto: { randomUUID: () => "search-fixture" },
  document: { querySelectorAll: () => [] },
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  setInterval, setTimeout,
});
vm.runInContext(testSource, context, { filename: rendererPath });
const { filterLoadedGroups, loadedSearchIndex, normalizedLoadedSearchText } = context.search;
const a = Object.freeze({ conversationKey: "a", title: "Review API errors", unread: true });
const b = Object.freeze({ conversationKey: "b", title: "Improve keyboard navigation", statusType: "loading" });
const c = Object.freeze({ conversationKey: "c", title: "Plan the weekend" });
const groups = Object.freeze([
  Object.freeze({ key: "project-a", kind: "project", hostId: "local", name: "DESIGN project", tasks: Object.freeze([a, b]) }),
  Object.freeze({ key: "project-b", kind: "project", hostId: "peer", name: "Empty folder", tasks: Object.freeze([]) }),
  Object.freeze({ key: "recent", kind: "recent", hostId: "peer", name: "Recents", tasks: Object.freeze([c]) }),
]);
assert.equal(filterLoadedGroups(groups, "  ", "all")[0], groups[0], "unfiltered models keep references");
assert.equal(filterLoadedGroups(groups, "design", "all")[0].tasks, groups[0].tasks, "project matches retain all loaded tasks");
const taskMatch = filterLoadedGroups(groups, "errors API", "all");
assert.equal(taskMatch.length, 1);
assert.equal(taskMatch[0].tasks[0], a, "task identity, status and action metadata are retained");
assert.equal(taskMatch[0].searchResult, true);
assert.equal(filterLoadedGroups(groups, "ＡＰＩ", "all")[0].tasks[0], a);
assert.equal(filterLoadedGroups(groups, "empty", "peer")[0].key, "project-b", "empty project names remain searchable");
assert.equal(filterLoadedGroups(groups, "weekend", "peer")[0].kind, "recent");
assert.equal(filterLoadedGroups(groups, "Recents", "all").length, 0, "the Recents heading is not a project name");
assert.equal(filterLoadedGroups(groups, "API", "peer").length, 0, "device scope always applies");
assert.equal(filterLoadedGroups(groups, "[.*<script>", "all").length, 0, "queries are literal text");
assert.equal(groups[0].tasks.length, 2, "search never changes membership");
const cachedTaskIndex = loadedSearchIndex.get(a);
assert.ok(cachedTaskIndex && cachedTaskIndex.normalized === "review api errors", "task titles are indexed after their first search");
filterLoadedGroups(groups, "review", "all");
assert.equal(loadedSearchIndex.get(a), cachedTaskIndex, "successive queries reuse the normalized task-title index");
const mutable = { title: "First title" };
assert.equal(normalizedLoadedSearchText(mutable, mutable.title), "first title");
const firstMutableIndex = loadedSearchIndex.get(mutable);
mutable.title = "Changed title";
assert.equal(normalizedLoadedSearchText(mutable, mutable.title), "changed title");
assert.notEqual(loadedSearchIndex.get(mutable), firstMutableIndex, "a changed title invalidates its cached normalized value");
const many = [{ kind: "project", hostId: "peer", name: "Large project", tasks: Array.from({ length: 10000 }, (_, id) => ({ title: `Task ${id} ${id % 5 ? "layout" : "review"}` })) }];
assert.equal(filterLoadedGroups(many, "review", "all")[0].tasks.length, 2000, "large loaded inventories remain complete");
const largeIndex = loadedSearchIndex.get(many[0].tasks[0]);
filterLoadedGroups(many, "task 0", "all");
assert.equal(loadedSearchIndex.get(many[0].tasks[0]), largeIndex, "large successive searches reuse their title index");
console.log("Loaded search self-test passed (literal, Unicode, scope, cached normalization, immutability, recents, empty projects and 10,000 loaded chats).");
