"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const originalSource = fs.readFileSync(rendererPath, "utf8");
const testSource = originalSource
  .replace("(() => {", "globalThis.__statusInvalidationTest = (() => {")
  .replace(/  return install\(\);\r?\n\}\)\(\);\s*$/u, `  return {
    state, armRemoteProjectInventoryRefresh, mutationsChangeTaskPresentation, nativeTaskStatusObservedAt, schedule,
    configure(publish) {
      scheduleLocalProjectInventoryPublication = publish;
    },
  };\n})();`);
assert.notEqual(testSource, originalSource, "test adapter must replace startup");

class FixtureElement {
  constructor(parent = null, row = false) {
    this.parentElement = parent;
    this.row = row;
    this.attributes = new Map();
  }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  closest() {
    for (let item = this; item; item = item.parentElement) if (item.row) return item;
    return null;
  }
  matches() { return this.row; }
  querySelector() { return null; }
}

const timerDelays = [];
const context = vm.createContext({
  Element: FixtureElement,
  TextDecoder, TextEncoder, clearInterval, clearTimeout, console,
  crypto: { randomUUID: () => "status-invalidation-test" },
  document: { addEventListener() {}, querySelector: () => null, querySelectorAll: () => [], removeEventListener() {} },
  localStorage: { getItem: () => null, removeItem() {}, setItem() {} },
  queueMicrotask,
  requestAnimationFrame: () => 1,
  setInterval,
  setTimeout: (_callback, delay) => { timerDelays.push(delay); return timerDelays.length; },
});
context.globalThis = context;
vm.runInContext(testSource, context, { filename: rendererPath });

const fixture = context.__statusInvalidationTest;
const row = new FixtureElement(null, true);
row.setAttribute("data-app-action-sidebar-thread-id", "local:11111111-1111-4111-8111-111111111111");
row.setAttribute("data-app-action-sidebar-thread-host-id", "local");
const icon = new FixtureElement(row);
const outside = new FixtureElement();
const panel = new FixtureElement();
panel.contains = element => element === panel;
fixture.state.panel = panel;

assert.equal(fixture.mutationsChangeTaskPresentation([{ type: "attributes", target: icon }]), true,
  "a task icon/class mutation must invalidate its published status");
assert.equal(fixture.mutationsChangeTaskPresentation([{ type: "attributes", target: outside }]), false,
  "unrelated native mutations must not force status publication");
assert.equal(fixture.mutationsChangeTaskPresentation([{ type: "attributes", target: panel }]), false,
  "the injected panel must not invalidate itself");

const statusKey = "local::11111111-1111-4111-8111-111111111111";
const baseline = fixture.nativeTaskStatusObservedAt("local", "11111111-1111-4111-8111-111111111111", { statusState: { type: "loading" } });
assert.equal(baseline, 0, "a cold-start native spinner must begin without authority");
const changedAt = Date.now();
fixture.state.nativeTaskStatusMutationAt.set(statusKey, changedAt);
const confirmed = fixture.nativeTaskStatusObservedAt("local", "11111111-1111-4111-8111-111111111111", { statusState: { type: "idle" } });
assert.equal(confirmed, changedAt, "a post-baseline status mutation must become authoritative");

const publications = [];
fixture.configure(force => publications.push(force));
fixture.schedule([{ type: "attributes", attributeName: "class", target: icon, addedNodes: [], removedNodes: [] }]);
assert.deepEqual(publications, [true], "a native task status mutation must request immediate forced publication");

assert.match(originalSource, /localInventoryPublisherForceQueued/u,
  "status changes arriving during a publish must queue one follow-up publication");

const remoteHost = "remote-control:status-fixture";
fixture.state.remoteProjectInventories.set(remoteHost, {
  tasks: new Map([["working", { statusType: "loading" }]]), threads: [],
});
fixture.armRemoteProjectInventoryRefresh(new Map([[remoteHost, { requestClient: {} }]]));
assert.equal(timerDelays.at(-1), 5000, "an active remote task must arm an independent five-second pull");
fixture.state.remoteInventoryTimer = null;
fixture.state.remoteProjectInventories.set(remoteHost, { tasks: new Map(), threads: [] });
fixture.armRemoteProjectInventoryRefresh(new Map([[remoteHost, { requestClient: {} }]]));
assert.equal(timerDelays.at(-1), 15000, "idle remote inventory polling must remain bounded");
console.log("Status invalidation self-test passed.");
