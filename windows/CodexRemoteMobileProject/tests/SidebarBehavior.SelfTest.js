"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// Exercise the renderer's real event and focus helpers without connecting to an
// app, changing a saved project, or invoking any native action.
let document;
class TestElement {
  constructor(tagName = "div") {
    this.tagName = tagName.toUpperCase();
    this.children = [];
    this.dataset = {};
    this.attributes = new Map();
    this.listeners = new Map();
    this.className = "";
    this.disabled = false;
    this.style = {};
    this.tabIndex = tagName === "button" ? 0 : -1;
    this.classList = {
      add: (...names) => { this.className = [...new Set([...this.className.split(/\s+/), ...names])].join(" ").trim(); },
      remove: (...names) => { this.className = this.className.split(/\s+/).filter(name => !names.includes(name)).join(" "); },
    };
  }
  get isConnected() { return this === document.body || Boolean(this.parentElement?.isConnected); }
  get ownerDocument() { return document; }
  get lastElementChild() { return this.children.at(-1) ?? null; }
  get textContent() { return this.children.length ? this.children.map(child => child.textContent).join("") : this.text ?? ""; }
  set textContent(value) { this.text = String(value); this.children = []; }
  set innerHTML(value) {
    this.children = [];
    for (const match of value.matchAll(/<span(?:\s[^>]*)?>(.*?)<\/span>/gu)) {
      const span = new TestElement("span");
      span.textContent = match[1];
      this.appendChild(span);
    }
  }
  setAttribute(name, value) {
    this.attributes.set(name, String(value));
    if (name === "id") this.id = String(value);
  }
  getAttribute(name) {
    if (name.startsWith("data-")) return this.dataset[name.slice(5).replace(/-([a-z])/gu, (_, letter) => letter.toUpperCase())] ?? null;
    return this.attributes.get(name) ?? null;
  }
  removeAttribute(name) { this.attributes.delete(name); }
  append(...nodes) { nodes.forEach(node => this.appendChild(node)); }
  appendChild(node) { node.parentElement = this; this.children.push(node); return node; }
  contains(node) { return node === this || this.children.some(child => child.contains(node)); }
  remove() {
    if (this.contains(document.activeElement)) document.activeElement = document.body;
    if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(child => child !== this);
    this.parentElement = null;
  }
  replaceChildren(...nodes) {
    for (const child of [...this.children]) child.remove();
    this.append(...nodes);
  }
  matches(selector) {
    const key = selector.match(/^\[data-crmp-focus-key="([\s\S]*)"\]$/u);
    if (key) return this.dataset.crmpFocusKey === key[1];
    if (selector.includes(",")) return selector.split(",").some(part => this.matches(part));
    if (selector === "[data-crmp-focus-key]") return Boolean(this.dataset.crmpFocusKey);
    if (selector.startsWith("#")) return this.id === selector.slice(1);
    if (selector === "button") return this.tagName === "BUTTON";
    if (selector === '[role="button"]') return this.getAttribute("role") === "button";
    const className = selector.match(/^\.([\w-]+)/u)?.[1];
    if (className && !this.className.split(/\s+/u).includes(className)) return false;
    const pressed = selector.match(/\[aria-pressed="(true|false)"\]/u)?.[1];
    if (pressed && this.getAttribute("aria-pressed") !== pressed) return false;
    return Boolean(className);
  }
  closest(selector) { return this.matches(selector) ? this : this.parentElement?.closest(selector) ?? null; }
  querySelectorAll(selector) {
    return this.children.flatMap(child => [...(child.matches(selector) ? [child] : []), ...child.querySelectorAll(selector)]);
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
  addEventListener(name, handler) {
    if (!this.listeners.has(name)) this.listeners.set(name, []);
    this.listeners.get(name).push(handler);
  }
  fire(name, fields = {}) {
    const event = { type: name, key: "", defaultPrevented: false, propagationStopped: false, target: this,
      preventDefault() { this.defaultPrevented = true; }, stopPropagation() { this.propagationStopped = true; },
      stopImmediatePropagation() { this.propagationStopped = true; }, ...fields };
    document.fire(name, event);
    for (const handler of this.listeners.get(name) ?? []) handler(event);
    return event;
  }
  focus() { if (!this.disabled && this.isConnected) document.activeElement = this; }
  click() { if (!this.disabled) this.clickCount = (this.clickCount ?? 0) + 1; }
  getClientRects() { return this.isConnected && !this.hidden ? [{}] : []; }
  getBoundingClientRect() { return { left: 12, right: 220, top: 30, bottom: 60 }; }
}
document = {
  listeners: new Map(),
  body: new TestElement("body"),
  createElement: tag => new TestElement(tag),
  querySelectorAll: selector => document.body.querySelectorAll(selector),
  querySelector: selector => document.body.querySelector(selector),
  getElementById: id => document.body.querySelector(`#${id}`),
  addEventListener(name, handler) {
    if (!this.listeners.has(name)) this.listeners.set(name, new Set());
    this.listeners.get(name).add(handler);
  },
  removeEventListener(name, handler) { this.listeners.get(name)?.delete(handler); },
  fire(name, event) { for (const handler of [...(this.listeners.get(name) ?? [])]) handler(event); },
};
document.activeElement = document.body;

const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const originalSource = fs.readFileSync(rendererPath, "utf8");
const testSource = originalSource
  .replace("(() => {", "globalThis.__sidebarTest = (() => {")
  .replace(/  return install\(\);\r?\n\}\)\(\);\s*$/u, `  return {
    state, button, setFocusKey, nativeElementDisabled, invokeNativeElement, bindActivation,
    captureSidebarFocus, restoreSidebarFocus, restoreRenderedFocus,
    focusProjectOverlay, bindOverlayKeyboard, openProjectContextMenu,
    closeProjectOverlays, projectCard, projectContextMenu, bindReorder,
    setRender: (hook) => { render = hook; },
    setCommands: (commands) => { nativeProjectCommands = () => commands; },
    setReorder: (element, handler, scheduled) => {
      reorderElement = () => element; nativeKeyboardReorder = () => handler;
      sortableSnapshot = () => ({ itemId: "project", items: ["project", "other"] }); schedule = scheduled;
    },
  };\n})();`);
assert.notEqual(testSource, originalSource, "test adapter must replace startup");
const context = vm.createContext({
  Element: TestElement, Node: TestElement, CSS: { escape: value => value },
  TextDecoder, TextEncoder, clearInterval, clearTimeout, console,
  crypto: { randomUUID: () => "sidebar-behavior-test" }, document,
  localStorage: { getItem: () => null, removeItem: () => {}, setItem: () => {} },
  setInterval, setTimeout,
});
vm.runInContext(testSource, context, { filename: rendererPath });
const sidebar = context.__sidebarTest;
assert.ok(sidebar?.restoreRenderedFocus, "renderer startup must remain disabled in the test adapter");
const panel = document.createElement("div");
panel.id = "codex-remote-mobile-project-panel";
document.body.appendChild(panel);
sidebar.state.panel = panel;

function keyedButton(...key) { return sidebar.setFocusKey(sidebar.button("", "fixture"), ...key); }
const originalFilter = keyedButton("filter", "host-a");
panel.appendChild(originalFilter);
originalFilter.focus();
const filterFocus = sidebar.captureSidebarFocus();
const replacementFilter = keyedButton("filter", "host-a");
panel.replaceChildren(replacementFilter);
assert.equal(document.activeElement, document.body, "replacing a focused control reproduces lost focus");
sidebar.restoreSidebarFocus(filterFocus);
assert.equal(document.activeElement, replacementFilter, "inventory refresh must retain the focused device filter");

const group = document.createElement("section");
group.className = "crmp-project";
const toggle = keyedButton("project", "fixture", "toggle");
toggle.className = "crmp-project-toggle";
const task = keyedButton("task", "local", "fixture-task");
group.append(toggle, task);
panel.replaceChildren(group);
task.focus();
const taskFocus = sidebar.captureSidebarFocus();
task.remove();
sidebar.restoreSidebarFocus(taskFocus);
assert.equal(document.activeElement, toggle, "a disappearing task must return focus to its surviving project");
const outside = document.createElement("button");
document.body.appendChild(outside);
outside.focus();
assert.equal(sidebar.captureSidebarFocus(), null);
sidebar.restoreSidebarFocus(null);
assert.equal(document.activeElement, outside, "background sidebar updates must not move composer focus");

const project = { key: "fixture", name: "Fixture project", cwd: "/fixture", hostId: "local", tasks: [] };
const noop = () => { throw new Error("The test must never execute a project command"); };
sidebar.setCommands([
  { id: "pin-project", label: "Unpin", enabled: true, onSelect: noop },
  { id: "edit-project", label: "Edit", enabled: false, onSelect: noop },
  { id: "reveal-project-folder", label: "Open in Explorer", enabled: true, onSelect: noop },
  { id: "archive-project-threads", enabled: true },
  { id: "remove-project", label: "Remove project", enabled: true, onSelect: noop },
]);
const card = sidebar.projectCard(project);
assert.equal(card.getAttribute("role"), "dialog");
assert.deepEqual(card.querySelectorAll("button").map(item => item.disabled), [false, false, true],
  "details availability must follow each native command");
assert.equal(card.querySelector("button").getAttribute("aria-label"), "Unpin");
const menu = sidebar.projectContextMenu(project);
assert.equal(menu.getAttribute("role"), "menu");
assert.deepEqual(menu.querySelectorAll("button").map(item => item.disabled), [false, true, false, true, false],
  "missing callbacks and disabled commands must not appear actionable");
document.body.appendChild(menu);
sidebar.focusProjectOverlay(menu);
const enabledItems = menu.querySelectorAll("button").filter(item => !item.disabled);
assert.equal(document.activeElement, enabledItems[0]);
let event = menu.fire("keydown", { key: "ArrowDown" });
assert.equal(document.activeElement, enabledItems[1], "ArrowDown must skip a disabled command");
assert.equal(event.defaultPrevented, true);
menu.fire("keydown", { key: "End" });
assert.equal(document.activeElement, enabledItems[2]);
menu.fire("keydown", { key: "ArrowDown" });
assert.equal(document.activeElement, enabledItems[0], "ArrowDown must wrap at the end of the menu");
menu.fire("keydown", { key: "ArrowUp" });
assert.equal(document.activeElement, enabledItems[2]);
menu.fire("keydown", { key: "Home" });
assert.equal(document.activeElement, enabledItems[0]);
menu.fire("keydown", { key: "o" });
assert.equal(document.activeElement, enabledItems[1], "typeahead must use command labels");

let restoredToggle;
sidebar.state.contextProjectKey = project.key;
sidebar.state.overlayFocusReturnKey = toggle.dataset.crmpFocusKey;
sidebar.setRender(() => {
  const snapshot = sidebar.captureSidebarFocus();
  menu.remove();
  restoredToggle = keyedButton("project", "fixture", "toggle");
  panel.replaceChildren(restoredToggle);
  sidebar.restoreRenderedFocus(snapshot);
});
event = menu.fire("keydown", { key: "Escape" });
assert.equal(event.defaultPrevented, true);
assert.equal(event.propagationStopped, true);
assert.equal(sidebar.state.contextProjectKey, null);
assert.equal(document.activeElement, restoredToggle, "Escape must return focus to the recreated opener");

sidebar.setCommands([]);
const unavailableCard = sidebar.projectCard(project);
assert.equal(unavailableCard.querySelectorAll("button").every(item => item.disabled), true,
  "the presence of a native menu trigger must not enable missing commands");
document.body.appendChild(unavailableCard);
sidebar.focusProjectOverlay(unavailableCard);
assert.equal(document.activeElement, unavailableCard, "an informational details card must still receive keyboard focus");
unavailableCard.remove();

const disabledButton = document.createElement("button");
document.body.appendChild(disabledButton);
disabledButton.disabled = true;
assert.equal(sidebar.invokeNativeElement(disabledButton), false);
disabledButton.disabled = false;
disabledButton.setAttribute("aria-disabled", "true");
assert.equal(sidebar.invokeNativeElement(disabledButton), false);
assert.equal(disabledButton.clickCount ?? 0, 0, "disabled native controls must never be invoked");
disabledButton.setAttribute("aria-disabled", "false");
assert.equal(sidebar.invokeNativeElement(disabledButton), true);
assert.equal(disabledButton.clickCount, 1);

const activationButton = document.createElement("button");
document.body.appendChild(activationButton);
let activations = 0;
sidebar.bindActivation(activationButton, () => { activations++; });
const pointer = { pointerId: 1, button: 0, clientX: 20, clientY: 40 };
activationButton.fire("pointerup", pointer);
assert.equal(activations, 0, "releasing over an action after pressing elsewhere must not invoke it");
activationButton.fire("pointerdown", pointer);
activationButton.fire("pointerup", pointer);
activationButton.fire("click", { detail: 1 });
assert.equal(activations, 1, "a complete pointer click must invoke an action exactly once");
activationButton.fire("pointerdown", pointer);
document.fire("pointerup", { ...pointer, type: "pointerup", target: outside });
activationButton.fire("pointerup", pointer);
assert.equal(activations, 1, "a pointer released outside must clear its original press");
activationButton.fire("pointerdown", pointer);
activationButton.fire("pointercancel", pointer);
activationButton.fire("pointerup", pointer);
assert.equal(activations, 1, "a canceled pointer gesture must not invoke an action");
activationButton.fire("pointerdown", pointer);
activationButton.fire("pointerup", { ...pointer, clientX: 500 });
activationButton.fire("click", { detail: 1 });
assert.equal(activations, 1, "a captured touch released outside button bounds must not invoke it");
activationButton.fire("click", { detail: 0 });
assert.equal(activations, 2, "keyboard and programmatic clicks must remain available after a canceled pointer click");
assert.equal([...document.listeners.values()].reduce((total, handlers) => total + handlers.size, 0), 0,
  "completed gestures must remove temporary document tracking");

const nativeProject = document.createElement("div");
nativeProject.setAttribute("role", "button");
let reorderCalls = 0;
let scheduleCalls = 0;
sidebar.setReorder(nativeProject, nativeEvent => {
  reorderCalls++;
  assert.equal(nativeEvent.target, nativeProject);
  assert.equal(nativeEvent.key, "ArrowDown");
}, () => { scheduleCalls++; });
const reorderButton = document.createElement("button");
sidebar.bindReorder(reorderButton, document.createElement("div"), { kind: "project" });
reorderButton.fire("keydown", { key: "ArrowDown" });
reorderButton.fire("keydown", { key: "ArrowDown", altKey: true, shiftKey: true });
assert.equal(reorderCalls, 0, "ordinary navigation must not reorder projects");
event = reorderButton.fire("keydown", { key: "ArrowDown", altKey: true });
assert.equal(reorderCalls, 1, "Alt+ArrowDown must forward the native keyboard reorder action once");
assert.equal(event.defaultPrevented, true);
assert.equal(scheduleCalls, 1);

console.log("Sidebar behavior self-test passed.");
