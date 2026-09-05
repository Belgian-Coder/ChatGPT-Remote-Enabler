"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// Small dependency-free DOM fixture. These tests execute the renderer's real
// layout functions; native application actions and background work are stubbed.
class FixtureElement {
  constructor(tagName = "div", nodeType = 1) {
    this.tagName = tagName.toUpperCase();
    this.nodeType = nodeType;
    this.attributes = new Map();
    this.children = [];
    this.parentElement = null;
    this._text = "";
    this.listeners = new Map();
    this.style = {
      setProperty(name, value) { this[name.replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value; },
      getPropertyValue(name) { return this[name.replace(/-([a-z])/g, (_, c) => c.toUpperCase())] || ""; },
      removeProperty(name) { delete this[name.replace(/-([a-z])/g, (_, c) => c.toUpperCase())]; },
    };
    this.dataset = new Proxy({}, {
      get: (_, name) => this.getAttribute(`data-${String(name).replace(/[A-Z]/g, c => `-${c.toLowerCase()}`)}`) ?? undefined,
      set: (_, name, value) => { this.setAttribute(`data-${String(name).replace(/[A-Z]/g, c => `-${c.toLowerCase()}`)}`, value); return true; },
    });
    this.classList = {
      add: (...names) => { this.className = [...new Set([...this.className.split(/\s+/).filter(Boolean), ...names])].join(" "); },
      remove: (...names) => { this.className = this.className.split(/\s+/).filter(name => !names.includes(name)).join(" "); },
      contains: name => this.className.split(/\s+/).includes(name),
      toggle: (name, force) => {
        const enabled = force ?? !this.classList.contains(name);
        if (enabled) this.classList.add(name); else this.classList.remove(name);
        return enabled;
      },
    };
  }
  get className() { return this.getAttribute("class") || ""; }
  set className(value) { this.setAttribute("class", value); }
  get id() { return this.getAttribute("id") || ""; }
  set id(value) { this.setAttribute("id", value); }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(""); }
  set textContent(value) { this.replaceChildren(); this._text = String(value ?? ""); }
  get innerText() { return this.textContent; }
  get childElementCount() { return this.children.length; }
  get firstElementChild() { return this.children[0] || null; }
  get lastElementChild() { return this.children.at(-1) || null; }
  get isConnected() { return this.tagName === "DOCUMENT" || Boolean(this.parentElement?.isConnected); }
  get parentNode() { return this.parentElement; }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  hasAttribute(name) { return this.attributes.has(name); }
  removeAttribute(name) { this.attributes.delete(name); }
  appendChild(child) {
    if (child.nodeType === 11) { for (const item of [...child.children]) this.appendChild(item); return child; }
    child.remove();
    child.parentElement = this;
    this.children.push(child);
    return child;
  }
  append(...children) { for (const child of children) this.appendChild(child); }
  prepend(child) { child.remove(); child.parentElement = this; this.children.unshift(child); }
  insertBefore(child, reference) {
    child.remove();
    const index = this.children.indexOf(reference);
    assert.ok(index >= 0, "insertBefore reference must belong to the fixture parent");
    child.parentElement = this;
    this.children.splice(index, 0, child);
    return child;
  }
  replaceChildren(...children) {
    for (const child of this.children) child.parentElement = null;
    this.children = [];
    this._text = "";
    this.append(...children);
  }
  remove() {
    if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(child => child !== this);
    this.parentElement = null;
  }
  contains(target) { return this === target || this.children.some(child => child.contains(target)); }
  addEventListener(name, callback) { this.listeners.set(name, [...(this.listeners.get(name) || []), callback]); }
  removeEventListener() {}
  dispatchEvent(event) { for (const callback of this.listeners.get(event.type) || []) callback(event); return true; }
  click() { for (const callback of this.listeners.get("click") || []) callback({ preventDefault() {}, stopPropagation() {}, stopImmediatePropagation() {} }); }
  matches(selector) {
    return selector.split(/,(?![^\[]*\])/).some(part => {
      part = part.trim();
      const tokens = part.match(/(?:\[[^\]]*\]|[^\s])+/g) || [];
      const own = tokens.pop();
      if (!own || !this.matchesSimple(own)) return false;
      let ancestor = this.parentElement;
      while (tokens.length) {
        const token = tokens.pop();
        while (ancestor && !ancestor.matchesSimple(token)) ancestor = ancestor.parentElement;
        if (!ancestor) return false;
        ancestor = ancestor.parentElement;
      }
      return true;
    });
  }
  matchesSimple(selector) {
    const attributes = [...selector.matchAll(/\[([^\s~|^$*=\]]+)(?:(\^=|\*=|\$=|=)["']?([^"'\]]*)["']?)?\]/g)];
    const rest = selector.replace(/\[[^\]]*\]/g, "");
    const tag = rest.match(/^[\w-]+/);
    if (tag && this.tagName.toLowerCase() !== tag[0].toLowerCase()) return false;
    const id = rest.match(/#([\w-]+)/);
    if (id && this.id !== id[1]) return false;
    for (const match of rest.matchAll(/\.([\w-]+)/g)) if (!this.classList.contains(match[1])) return false;
    for (const [, name, operator, expected] of attributes) {
      const actual = this.getAttribute(name);
      if (actual === null) return false;
      if (operator === "=" && actual !== expected) return false;
      if (operator === "^=" && !actual.startsWith(expected)) return false;
      if (operator === "$=" && !actual.endsWith(expected)) return false;
      if (operator === "*=" && !actual.includes(expected)) return false;
    }
    return true;
  }
  closest(selector) { let el = this; while (el) { if (el.matches(selector)) return el; el = el.parentElement; } return null; }
  querySelectorAll(selector) {
    const result = [];
    for (const child of this.children) {
      if (child.matches(selector)) result.push(child);
      result.push(...child.querySelectorAll(selector));
    }
    return result;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  cloneNode(deep) {
    const clone = new FixtureElement(this.tagName, this.nodeType);
    clone.attributes = new Map(this.attributes);
    clone._text = this._text;
    clone.disabled = this.disabled;
    clone.computedStyle = { ...this.computedStyle };
    Object.assign(clone.style, this.style);
    if (deep) for (const child of this.children) clone.appendChild(child.cloneNode(true));
    return clone;
  }
  getBoundingClientRect() { return { x: 0, y: 0, width: 280, height: 30, top: 0, bottom: 30, left: 0, right: 280 }; }
}

const document = new FixtureElement("document", 9);
document.head = document.appendChild(new FixtureElement("head"));
document.body = document.appendChild(new FixtureElement("body"));
document.createElement = tag => new FixtureElement(tag);
document.createElementNS = (_, tag) => new FixtureElement(tag);
document.createDocumentFragment = () => new FixtureElement("fragment", 11);
document.getElementById = id => document.querySelector(`#${id}`);

const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const originalSource = fs.readFileSync(rendererPath, "utf8").replace(/\r\n/g, "\n");
assert.ok(originalSource.includes("  return install();\n})();"), "test entrypoint extraction must succeed before evaluating the renderer");
const schedules = [
  "scheduleLocalProjectInventoryPublication", "scheduleLocalPeerCacheInventory",
  "scheduleLocalRegisteredProjectsRefresh", "scheduleRemoteProjectInventory",
  "scheduleAutoRegistration", "scheduleAutoReconciliation", "scheduleAutoArchive",
  "scheduleNativeInventoryHydration",
];
const testSource = originalSource
  .replace("(() => {", "globalThis.__sidebarLayoutTest = (() => {")
  .replace("  return install();\n})();", `
  ${schedules.map(name => `${name} = () => {};`).join("\n  ")}
  bindReorder = () => {};
  probe = () => ({});
  nativeThreadAction = () => null;
  return { appendEmptyProjectState, appendGroup, commonAncestor, ensureStyle, install, nativeFolderIcon, nativeListContainer, plainFolderIcon, render, state,
    useModel(model) { collectModel = () => model; }
  };
})();`);
assert.notEqual(testSource, originalSource, "test entrypoint extraction must succeed");
const context = vm.createContext({
  CSS: { escape: value => String(value) },
  Element: FixtureElement,
  CustomEvent: class CustomEvent { constructor(type, options = {}) { this.type = type; this.detail = options.detail; } },
  MutationObserver: class MutationObserver { disconnect() {} observe() {} },
  Node: FixtureElement,
  TextDecoder,
  TextEncoder,
  clearInterval,
  clearTimeout,
  console,
  crypto: { randomUUID: () => "sidebar-layout-fixture" },
  document,
  getComputedStyle: element => new Proxy({ ...element.computedStyle, ...element.style }, { get: (target, key) => target[key] ?? "" }),
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  performance: { now: () => 1000 },
  requestAnimationFrame: () => 1,
  cancelAnimationFrame() {},
  setInterval,
  setTimeout,
});
context.globalThis = context;
const windowListeners = new Map();
context.addEventListener = (name, callback) => windowListeners.set(name, [...(windowListeners.get(name) || []), callback]);
context.removeEventListener = (name, callback) => windowListeners.set(name, (windowListeners.get(name) || []).filter(item => item !== callback));
context.dispatchEvent = (event) => {
  for (const callback of windowListeners.get(event.type) || []) callback(event);
  return true;
};
vm.runInContext(testSource, context, { filename: rendererPath });
const layout = context.__sidebarLayoutTest;

function element(tag, className, text) {
  const result = new FixtureElement(tag);
  if (className) result.className = className;
  if (text) result.textContent = text;
  return result;
}

function nativeProject(id, expanded, placeholder = "No chats") {
  const item = element("div", "group/cwd relative flex flex-col");
  item.setAttribute("role", "listitem");
  item.setAttribute("data-sidebar-project-kind", "local");
  item.setAttribute("data-app-action-sidebar-project-list-id", id);
  const row = item.appendChild(element("div", "sidebar-item group/folder-row text-sm"));
  row.setAttribute("role", "button");
  row.setAttribute("aria-expanded", String(expanded));
  row.setAttribute("data-app-action-sidebar-project-collapsed", String(!expanded));
  const iconSlot = row.appendChild(element("span", "icon-leading-slot"));
  const icon = iconSlot.appendChild(element("svg", "icon-xs shrink-0"));
  icon.setAttribute("viewBox", "0 0 16 16");
  const glyph = icon.appendChild(element("path"));
  glyph.setAttribute("d", expanded ? "native-open-current-package" : "native-closed-current-package");
  const title = row.appendChild(element("div", "text-base text-default", `Project ${id}`));
  title.computedStyle = { fontSize: "14px", fontWeight: "430", lineHeight: "21px", color: "native-default-color" };
  const create = row.appendChild(element("button", "native-create"));
  create.setAttribute("aria-label", `Start new chat in Project ${id}`);
  create.disabled = true;
  const actions = row.appendChild(element("button", "native-actions"));
  actions.setAttribute("aria-label", `Project actions for Project ${id}`);
  if (expanded && placeholder !== null) {
    const children = item.appendChild(element("div", "pt-0.5 pb-2"));
    children.appendChild(element("div")).appendChild(element("div", "text-codex-description opacity-50 px-8 py-1 text-base", placeholder));
  }
  return item;
}

function project(id, tasks = []) {
  return { key: `local:${id}`, kind: "project", hostId: "local", hostName: "Fixture Desktop", projectId: id, cwd: `C:\\Fixture\\${id}`, name: `Project ${id}`, tasks };
}

const nav = document.body.appendChild(element("nav"));
nav.appendChild(element("button", "native-global-control", "New chat"));
nav.appendChild(element("button", "native-global-control", "Explore"));
const nativeContainer = nav.appendChild(element("div", "contents"));
const projectsSection = nativeContainer.appendChild(element("div")).appendChild(element("section"));
const recentsSection = nativeContainer.appendChild(element("div")).appendChild(element("section"));
const recentHeading = recentsSection.appendChild(element("div", "group/nav-section-title"));
const recentNewChat = recentHeading.appendChild(element("button", "sidebar-icon-button"));
recentNewChat.setAttribute("aria-label", "New chat");
const opened = projectsSection.appendChild(nativeProject("empty-open", true));
const closed = projectsSection.appendChild(nativeProject("empty-closed", false));
const populated = projectsSection.appendChild(nativeProject("populated", true, null));
const nativeRecentRow = recentsSection.appendChild(element("button", "native-recent-row"));
nativeRecentRow.setAttribute("data-app-action-sidebar-thread-row", "true");
layout.state.filter = "local";

// Empty folders retain native text, indentation and spacing only while open.
const expandedFragment = document.createDocumentFragment();
layout.appendGroup(expandedFragment, project("empty-open"));
const expandedGroup = expandedFragment.firstElementChild;
assert.equal(expandedGroup.querySelector(".crmp-project-toggle").getAttribute("aria-expanded"), "true");
const empty = expandedGroup.querySelector(".crmp-tasks .text-codex-description");
assert.ok(empty, "an expanded empty project must show the native empty-chat placeholder");
assert.equal(empty.textContent, "No chats");
for (const name of ["opacity-50", "px-8", "py-1", "text-base"]) assert.ok(empty.classList.contains(name), `native empty class ${name} must survive`);
assert.ok(empty.closest('[class*="pt-0.5"][class*="pb-2"]'), "native child-list vertical spacing must survive");
assert.notEqual(empty, opened.querySelector(".text-codex-description"), "native DOM must be cloned, never moved");
assert.ok(opened.querySelector(".text-codex-description"), "rendering must preserve the native empty state");

layout.state.collapsed.delete("local:empty-closed");
const collapsedFragment = document.createDocumentFragment();
layout.appendGroup(collapsedFragment, project("empty-closed"));
assert.equal(collapsedFragment.querySelector(".crmp-project-toggle").getAttribute("aria-expanded"), "false", "native collapsed state must outrank stale custom expansion");
assert.equal(collapsedFragment.querySelector(".crmp-tasks"), null, "collapsed folders must not reserve a child-list gap");
assert.equal(collapsedFragment.textContent.includes("No chats"), false, "collapsed empty folders must not show a placeholder");

const task = { title: "Fixture task", conversationId: "fixture-task", hostId: "local", statusType: "idle", selected: false, unread: false };
const populatedFragment = document.createDocumentFragment();
layout.appendGroup(populatedFragment, project("populated", [task]));
assert.equal(populatedFragment.querySelectorAll(".crmp-task-row").length, 1);
assert.equal(populatedFragment.textContent.includes("No chats"), false, "populated folders must not show an empty placeholder");

// Use the installed app's exact state glyphs. Copying older hardcoded paths into
// a newer app's SVG changes the icon even when the logical state is correct.
const openIcon = layout.nativeFolderIcon(project("empty-open"), true);
assert.equal(openIcon.querySelector("path").getAttribute("d"), "native-open-current-package");
const closedIcon = layout.nativeFolderIcon(project("empty-open"), false);
assert.equal(closedIcon.querySelector("path").getAttribute("d"), "native-closed-current-package");
assert.notEqual(openIcon, opened.querySelector("svg"));
assert.notEqual(closedIcon, closed.querySelector("svg"));
assert.equal(layout.nativeFolderIcon(project("empty-closed"), true).querySelector("path").getAttribute("d"), "native-open-current-package");
assert.notEqual(layout.plainFolderIcon(true).querySelector("path").getAttribute("d"), layout.plainFolderIcon(false).querySelector("path").getAttribute("d"));

// A recent chat in a sibling section must not narrow the replacement mount to
// Recents and leave the native Projects section duplicated above the custom view.
assert.equal(layout.commonAncestor([nativeRecentRow, opened, closed]), nativeContainer);
assert.equal(layout.nativeListContainer([nativeRecentRow], [opened, closed]), nativeContainer);
assert.equal(layout.nativeListContainer([], [opened, closed]), nativeContainer, "empty Recents must not leave the native Projects heading and Recents sibling outside the replacement");
layout.state.panel = element("div");
layout.state.panel.id = "codex-remote-mobile-project-panel";
layout.state.view = "native";
let updateStatus = { state: "current", version: "v1.5.32", message: null, canCancel: false, canQueue: false };
const updateActions = [];
context.__CHATGPT_REMOTE_UPDATE__ = {
  getStatus: () => updateStatus,
  request: (action) => { updateActions.push(action); },
};
layout.useModel({ rows: [nativeRecentRow], nativeProjectItems: [opened, closed], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.install();
assert.equal(layout.state.nativeContainer, nativeContainer, "render must include native project items as well as task rows when choosing its mount");
assert.equal(layout.state.panel.parentElement, nav, "mode controls must mount beside the common Projects/Recents container");
assert.equal(layout.state.panel.querySelector(".crmp-update-status").textContent, "Current · v1.5.32");
updateStatus = { state: "available", version: "v1.5.33", message: "Ready", canCancel: false, canQueue: true };
context.dispatchEvent(new context.CustomEvent("chatgpt-remote-update-status"));
assert.equal(layout.state.updateStatus.state, "available", "a window-dispatched updater event without detail must refresh through getStatus");
layout.render();
let updateControl = layout.state.panel.querySelector(".crmp-update-control");
assert.equal(updateControl.textContent, "Update available · v1.5.33", "the canonical available state must be visible in Native views");
updateControl.click();
assert.deepEqual(updateActions, ["queue"], "the renderer must only ask the updater to queue an available release");
layout.useModel({ rows: [], nativeProjectItems: [opened, closed], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.equal(layout.state.nativeContainer, nativeContainer, "an empty recent-task inventory must keep the whole native list mounted consistently");
assert.ok(nav.querySelector(".native-global-control"), "choosing the list mount must preserve global sidebar controls");

layout.state.view = "mobile";
layout.useModel({
  rows: [nativeRecentRow], nativeProjectItems: [opened, closed],
  hosts: [{ id: "local", name: "Fixture Desktop" }], remoteRuntimes: [],
  projects: [project("empty-open"), project("empty-closed")],
  recents: [{ key: "fixture-recent", kind: "recent", hostId: "local", hostName: "Fixture Desktop", name: "Recent chats", tasks: [task] }],
});
layout.render();
updateControl = layout.state.panel.querySelector(".crmp-update-control");
assert.equal(updateControl.textContent, "Update available · v1.5.33", "the update control must remain visible in Mobile projects");
updateStatus = { state: "preparing", version: "v1.5.33", message: "Waiting to close", canCancel: true, canQueue: false };
document.dispatchEvent(new context.CustomEvent("chatgpt-remote-update-status", { detail: updateStatus }));
assert.equal(layout.state.updateStatus.state, "preparing", "a document-dispatched status detail must be accepted directly");
layout.render();
assert.equal(layout.state.panel.querySelector(".crmp-update-label").textContent, "Preparing update…");
const cancelUpdate = layout.state.panel.querySelector(".crmp-update-cancel");
assert.equal(cancelUpdate.textContent, "Cancel", "preparing must retain an explicit cancel action while canCancel is true");
cancelUpdate.click();
assert.deepEqual(updateActions, ["queue", "cancel"]);
const headings = layout.state.panel.querySelectorAll(".crmp-title");
assert.deepEqual(headings.map(heading => heading.textContent), ["Projects", "Recents"]);
for (const heading of headings) {
  for (const name of ["text-base", "font-medium", "text-tertiary", "opacity-75"]) {
    assert.ok(heading.classList.contains(name), `section heading must follow the native ${name} typography contract`);
  }
}
const recentGroup = layout.state.panel.querySelector('[data-project-key="fixture-recent"]');
assert.ok(recentGroup.querySelector(".crmp-task-row"));
assert.equal(recentGroup.querySelector(".crmp-project-head"), null, "a single recent-task group must not add a synthetic folder absent from native Recents");
assert.equal(nativeContainer.style.display, "none", "Mobile projects must replace both native sections together");
layout.state.view = "native";
layout.render();
assert.notEqual(nativeContainer.style.display, "none", "switching back must restore the native container display");

const legacyContainer = nav.appendChild(element("div", "legacy-native-list"));
const legacyRow = legacyContainer.appendChild(element("button"));
legacyRow.setAttribute("data-app-action-sidebar-thread-row", "true");
assert.equal(layout.nativeListContainer([legacyRow], []), legacyContainer, "legacy sectionless lists must retain their safe common ancestor");
const unsafeSection = nav.appendChild(element("section"));
const unsafeRow = unsafeSection.appendChild(element("button"));
unsafeRow.setAttribute("data-app-action-sidebar-thread-row", "true");
unsafeSection.appendChild(element("button", "", "Explore"));
assert.equal(layout.nativeListContainer([unsafeRow], []), null, "a section containing global navigation must never become the replacement mount");
const otherSection = nav.appendChild(element("section"));
const otherRow = otherSection.appendChild(element("button"));
otherRow.setAttribute("data-app-action-sidebar-thread-row", "true");
assert.equal(layout.nativeListContainer([legacyRow, otherRow], []), null, "a nav/body fallback must never hide the entire sidebar shell");

// Missing native rows still receive a useful empty state, without borrowing
// project names, host IDs or stale native task content.
nativeContainer.remove();
const remoteEmpty = element("div", "crmp-tasks");
layout.appendEmptyProjectState(remoteEmpty, { ...project("unregistered"), hostId: "fixture-peer" });
assert.equal(remoteEmpty.textContent, "No loaded chats", "missing remote inventory must not be represented as an authoritative empty project");
for (const name of ["opacity-50", "px-8", "py-1", "text-base"]) assert.ok(remoteEmpty.querySelector(".text-codex-description").classList.contains(name), `fallback empty class ${name} must match native`);

layout.ensureStyle();
const stylesheet = document.getElementById("codex-remote-mobile-project-style").textContent;
assert.match(stylesheet, /\.crmp-project-name\s*\{[^}]*text-overflow:\s*ellipsis/, "long project labels must remain bounded");
assert.match(stylesheet, /\.crmp-chip\s*\{[^}]*white-space:\s*nowrap/, "device labels must not split across lines");
assert.match(stylesheet, /\.crmp-filters\s*\{[^}]*flex-wrap:\s*wrap/, "device chips must wrap within a narrow sidebar");
assert.match(stylesheet, /\.crmp-project-list\s*\{[^}]*gap:\s*1px/, "project rows must use native one-pixel list separation");
assert.match(stylesheet, /\.crmp-project-toggle\s*\{[^}]*column-gap:\s*8px/, "project name indentation must align with the native 32-pixel leading slot");
assert.match(stylesheet, /\.crmp-project-toggle\s*\{[^}]*font-size:\s*14px;[^}]*line-height:\s*21px/, "project names must keep native base text metrics");
assert.equal(expandedGroup.querySelector(".crmp-project-new").disabled, true, "cloning an icon button must preserve native disabled state");

console.log("Sidebar layout self-test passed.");
