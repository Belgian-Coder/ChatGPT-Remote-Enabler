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
    this.replaceChildrenCalls = 0;
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
  get childNodes() {
    const textNode = this._text ? [{ nodeType: 3, nodeValue: this._text }] : [];
    return [...textNode, ...this.children];
  }
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
    this.replaceChildrenCalls += 1;
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
assert.ok(originalSource.includes("  return installWhenDocumentReady(api, state, install, probe);\n})();"), "test entrypoint extraction must succeed before evaluating the renderer");
const schedules = [
  "scheduleLocalProjectInventoryPublication", "scheduleLocalPeerCacheInventory",
  "scheduleLocalRegisteredProjectsRefresh", "scheduleRemoteProjectInventory",
  "scheduleAutoRegistration", "scheduleAutoReconciliation", "scheduleAutoArchive",
  "scheduleNativeInventoryHydration",
];
const testSource = originalSource
  .replace("(() => {", "globalThis.__sidebarLayoutTest = (() => {")
  .replace("  return installWhenDocumentReady(api, state, install, probe);\n})();", `
  ${schedules.map(name => `${name} = () => {};`).join("\n  ")}
  bindReorder = () => {};
  probe = () => ({});
  nativeThreadAction = () => null;
  return { appendEmptyProjectState, appendGroup, canDirectArchiveTask, commonAncestor, emptyInventoryMessage, ensureStyle, freshDirectDeviceInventory, freshDirectThreadInventory, install, inventoryLabel, nativeFolderIcon, nativeListContainer, nativeListContainers, plainFolderIcon, reactRootFibers, render, sidebarMountAnchor, state,
    config, useModel(model) { collectModel = () => model; }
  };
})();`);
assert.notEqual(testSource, originalSource, "test entrypoint extraction must succeed");
const microtasks = [];
const aliasEnvironmentPrefix = "remote-control:" + "env" + "_";
const storage = new Map([["codex-remote-mobile-device-aliases-v1", JSON.stringify({ [`${aliasEnvironmentPrefix}fixture_zulu`]: "Bravo Alias" })]]);
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
  localStorage: {
    getItem: key => storage.get(key) ?? null,
    setItem: (key, value) => storage.set(key, String(value)),
    removeItem: key => storage.delete(key),
  },
  performance: { now: () => 1000 },
  queueMicrotask: callback => microtasks.push(callback),
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
const sidebarScroll = nav.appendChild(element("div", "sidebar-scroll"));
sidebarScroll.setAttribute("data-app-action-sidebar-scroll", "true");
const nativeContainer = sidebarScroll.appendChild(element("div", "contents"));
const projectsSection = nativeContainer.appendChild(element("div")).appendChild(element("section"));
const recentsSection = nativeContainer.appendChild(element("div")).appendChild(element("section"));
projectsSection.setAttribute("data-app-action-sidebar-section", "projects");
recentsSection.setAttribute("data-app-action-sidebar-section", "recents");
const recentHeading = recentsSection.appendChild(element("div", "group/nav-section-title"));
const recentNewChat = recentHeading.appendChild(element("button", "sidebar-icon-button"));
recentNewChat.setAttribute("aria-label", "New chat");
const opened = projectsSection.appendChild(nativeProject("empty-open", true));
const closed = projectsSection.appendChild(nativeProject("empty-closed", false));
const populated = projectsSection.appendChild(nativeProject("populated", true, null));
const nativeRecentRow = recentsSection.appendChild(element("button", "native-recent-row"));
nativeRecentRow.setAttribute("data-app-action-sidebar-thread-row", "true");
const reactRoot = { return: null };
const sectionFiber = { return: { return: reactRoot } };
projectsSection["__reactFiber$fixture"] = sectionFiber;
layout.state.filter = "local";
layout.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), threads: [], truncated: false });

// Empty folders retain native text, indentation and spacing only while open.
const expandedFragment = document.createDocumentFragment();
layout.appendGroup(expandedFragment, project("empty-open"));
const expandedGroup = expandedFragment.firstElementChild;
assert.equal(expandedGroup.querySelector(".crmp-project-toggle").getAttribute("aria-expanded"), "true");
const empty = expandedGroup.querySelector(".crmp-tasks .crmp-empty-project-message");
assert.ok(empty, "an expanded empty project must show the native empty-chat placeholder");
assert.equal(empty.textContent, "No chats");
for (const name of ["text-codex-description", "opacity-50", "px-8", "py-1", "text-base"]) {
  assert.ok(empty.classList.contains(name), `empty states must preserve native ${name} geometry and typography`);
}
assert.ok(empty.closest('[class*="pt-0.5"][class*="pb-2"]'), "native child-list vertical spacing must survive");
assert.notEqual(empty, opened.querySelector(".text-codex-description"), "native DOM must be cloned, never moved");
assert.ok(opened.querySelector(".text-codex-description"), "rendering must preserve the native empty state");

layout.state.collapsed.delete("local:empty-closed");
const collapsedFragment = document.createDocumentFragment();
layout.appendGroup(collapsedFragment, project("empty-closed"));
assert.equal(collapsedFragment.querySelector(".crmp-project-toggle").getAttribute("aria-expanded"), "false", "native collapsed state must outrank stale custom expansion");
assert.equal(collapsedFragment.querySelector(".crmp-tasks"), null, "collapsed folders must not reserve a child-list gap");
assert.equal(collapsedFragment.textContent.includes("No chats"), false, "collapsed empty folders must not show a placeholder");

const collapsedActiveFragment = document.createDocumentFragment();
layout.appendGroup(collapsedActiveFragment, project("empty-closed", [{
  title: "Active fixture", conversationId: "active-fixture", hostId: "local", statusType: "loading", selected: false, unread: false,
}]));
const collapsedActiveHead = collapsedActiveFragment.querySelector(".crmp-project-head");
assert.equal(collapsedActiveHead.dataset.hasStatus, "true", "collapsed active folders must reserve the native trailing status rail");
assert.ok(collapsedActiveHead.querySelector(".crmp-project-status-loading"), "collapsed active folders must retain their aggregate spinner");

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
assert.equal(layout.nativeListContainer([], []), nativeContainer, "stable Projects/Recents section markers must mount safely when all native rows are absent");
const discoveredReactRoots = layout.reactRootFibers();
assert.equal(discoveredReactRoots.length, 2, "stable sidebar anchors must expose only the distinct React anchor and root fibers");
assert.equal(discoveredReactRoots[0], sectionFiber, "stable sidebar anchors must expose their React fiber without a row");
assert.equal(discoveredReactRoots[1], reactRoot, "stable sidebar anchors must expose the React root without a row");
layout.state.panel = element("div");
layout.state.panel.id = "codex-remote-mobile-project-panel";
layout.state.view = "native";
layout.state.settingsOpen = true;
let updateStatus = { state: "current", version: "v1.5.32", message: null, canCancel: false, canQueue: false };
const updateActions = [];
context.__CHATGPT_REMOTE_UPDATE__ = {
  getStatus: () => updateStatus,
  request: (action) => { updateActions.push(action); },
};
layout.useModel({ rows: [nativeRecentRow], nativeProjectItems: [opened, closed], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.install();
assert.equal(layout.state.nativeContainer, nativeContainer, "render must include native project items as well as task rows when choosing its mount");
assert.equal(layout.state.panel.parentElement, sidebarScroll, "mode controls must mount beside the common Projects/Recents container");
layout.state.panel.remove();
assert.equal(layout.state.nativeContainer, nativeContainer, "the native sibling remains mounted in the React replacement regression");
layout.render();
assert.equal(layout.state.panel.parentElement, sidebarScroll, "render must remount a panel removed independently by React");
assert.equal(sidebarScroll.children.indexOf(layout.state.panel), sidebarScroll.children.indexOf(nativeContainer) - 1, "the recovered panel must be directly before the native list");
assert.equal(layout.state.panel.querySelector(".crmp-update-status").textContent, "Automatic update checks");
assert.match(layout.state.panel.querySelector(".crmp-version").textContent, /v1\.5\.32/u, "loaded version remains visible outside Settings");
updateStatus = { state: "available", version: "v1.5.33", message: "Ready", canCancel: false, canQueue: true };
context.dispatchEvent(new context.CustomEvent("chatgpt-remote-update-status"));
assert.equal(layout.state.updateStatus.state, "available", "a window-dispatched updater event without detail must refresh through getStatus");
layout.render();
let updateControl = layout.state.panel.querySelector(".crmp-update-control");
assert.equal(updateControl.textContent, "Update available · v1.5.33", "the canonical available state must be visible in Native views");
updateControl.click();
assert.deepEqual(updateActions, ["queue"], "the renderer must only ask the updater to queue an available release");
const attachedUpdater = context.__CHATGPT_REMOTE_UPDATE__;
layout.config.helperVersion = "v1.5.97";
updateStatus = { ...updateStatus, details: { installedVersion: "v1.5.96", availableVersion: "v1.5.98", history: [] } };
layout.render();
assert.match(layout.state.panel.querySelector(".crmp-version").textContent, /v1\.5\.96/u, "installed updater metadata must take precedence over dynamically loaded code");
const knownInstalledStatus = updateStatus;
updateStatus = { state: "current", version: "v1.5.96", details: { installedVersion: null, history: [] } };
layout.render();
assert.match(layout.state.panel.querySelector(".crmp-version").textContent, /v1\.5\.97 \(loaded\)/u, "explicit unknown installation metadata must not fall back to the old current version");
assert.match(layout.state.panel.textContent, /Installed helper: not reported/u, "history details must not label loaded code as installed");
updateStatus = knownInstalledStatus;
layout.render();
delete context.__CHATGPT_REMOTE_UPDATE__;
layout.render();
assert.equal(layout.state.updateStatus.state, "unavailable", "a disappeared bridge must invalidate cached available status");
assert.equal(layout.state.panel.querySelector(".crmp-update-control").textContent, "Update service disconnected", "a missing local service must not imply that releases or GitHub are unavailable");
assert.match(layout.state.panel.querySelector(".crmp-version").textContent, /v1\.5\.97 \(loaded\)/u, "a loaded version without installed metadata must be labelled explicitly");
assert.doesNotMatch(layout.state.panel.textContent, /Fully quit/u, "bridge loss must not instruct users to close ChatGPT");
context.__CHATGPT_REMOTE_UPDATE__ = attachedUpdater;
layout.render();
assert.equal(layout.state.updateStatus.state, "available", "reattaching the updater must restore live update status");
delete layout.config.helperVersion;
layout.useModel({ rows: [], nativeProjectItems: [opened, closed], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.equal(layout.state.nativeContainer, nativeContainer, "an empty recent-task inventory must keep the whole native list mounted consistently");
assert.ok(nav.querySelector(".native-global-control"), "choosing the list mount must preserve global sidebar controls");

// A new application build can expose the stable sidebar scroll capability
// before it renders any native project, task, or section marker. Mount there
// immediately so runtime discovery and inventory publication can start, then
// reanchor automatically when the native list arrives.
nativeContainer.remove();
layout.useModel({ rows: [], nativeProjectItems: [], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.equal(layout.sidebarMountAnchor(), sidebarScroll, "the stable sidebar scroll root must support an initially empty native sidebar");
assert.equal(layout.state.nativeContainer, null, "the scroll root must never be treated as a native list that can be hidden");
assert.equal(layout.state.mountAnchor, sidebarScroll, "readiness must track the capability-based mount anchor");
assert.equal(layout.state.panel.parentElement, sidebarScroll, "the panel must mount while native rows are still loading");
assert.notEqual(sidebarScroll.style.display, "none", "the stable sidebar shell must remain visible");
assert.equal(layout.state.panel.isConnected, true, "the fallback mount must be connected without a native list");

const projectsWrapper = projectsSection.parentElement;
const recentsWrapper = recentsSection.parentElement;
sidebarScroll.append(projectsWrapper, recentsWrapper);
layout.state.view = "mobile";
layout.useModel({ rows: [nativeRecentRow], nativeProjectItems: [opened, closed], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.equal(layout.nativeListContainer([nativeRecentRow], [opened, closed]), null, "the shared scroll root must never be returned as one hideable native list");
const directNativeContainers = layout.nativeListContainers([nativeRecentRow], [opened, closed]);
assert.equal(directNativeContainers.length, 2, "direct native section siblings must remain separate hideable containers");
assert.equal(directNativeContainers[0], projectsWrapper);
assert.equal(directNativeContainers[1], recentsWrapper);
assert.equal(layout.state.mountAnchor, sidebarScroll, "multiple native containers must keep the stable scroll root as their mount anchor");
assert.equal(sidebarScroll.style.display, undefined, "multi-section replacement must never hide the sidebar scroll root");
assert.equal(projectsWrapper.style.display, "none", "Mobile projects must hide the exact native Projects wrapper");
assert.equal(recentsWrapper.style.display, "none", "Mobile projects must hide the exact native Recents wrapper");
layout.useModel({ rows: [nativeRecentRow], nativeProjectItems: [], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.equal(layout.state.nativeContainers.length, 2, "a populated direct sibling must retain its empty marked sibling in the replacement set");
assert.equal(projectsWrapper.style.display, "none", "an empty marked Projects sibling must not remain duplicated beside Device projects");
assert.equal(recentsWrapper.style.display, "none", "the populated Recents sibling must remain hidden in Mobile projects mode");
const unrelatedSection = nav.appendChild(element("section"));
unrelatedSection.setAttribute("data-app-action-sidebar-section", "unrelated");
const emptyDirectContainers = layout.nativeListContainers([], []);
assert.equal(emptyDirectContainers.length, 0, "mixed legacy and modern section ownership in one sidebar must fail closed");
layout.useModel({ rows: [], nativeProjectItems: [], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.equal(layout.state.mountAnchor, null, "an unrelated scroll root must not claim readiness while a visible legacy section remains");
assert.equal(layout.state.panel.isConnected, false);
unrelatedSection.remove();
layout.useModel({ rows: [nativeRecentRow], nativeProjectItems: [], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.equal(layout.state.nativeContainers.length, 2, "pure modern direct sections must recover after mixed ownership disappears");

// A legacy layout whose empty marked sections are direct children of aside has
// no safe hideable list container. Never select and hide the aside shell.
sidebarScroll.remove();
const legacyAside = document.body.appendChild(element("aside"));
const legacyAsideProjects = legacyAside.appendChild(element("section"));
legacyAsideProjects.setAttribute("data-app-action-sidebar-section", "projects");
const legacyAsideRecents = legacyAside.appendChild(element("section"));
legacyAsideRecents.setAttribute("data-app-action-sidebar-section", "recents");
assert.equal(layout.nativeListContainer([], []), null, "the complete aside shell must never become a hideable native list");
assert.equal(layout.nativeListContainers([], []).length, 0);
legacyAside.remove();
nav.appendChild(sidebarScroll);
layout.useModel({ rows: [nativeRecentRow], nativeProjectItems: [], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();

// A scroll-root child can contain pinned controls beside the actual list. Keep
// the narrower proven list container instead of hiding that whole outer child.
const nestedNav = document.body.appendChild(element("nav"));
const nestedScroll = nestedNav.appendChild(element("div"));
nestedScroll.setAttribute("data-app-action-sidebar-scroll", "true");
const nestedOuter = nestedScroll.appendChild(element("div", "outer"));
const pinnedControl = nestedOuter.appendChild(element("button", "pinned-control", "Library"));
const nestedContents = nestedOuter.appendChild(element("div", "contents"));
const nestedSection = nestedContents.appendChild(element("section"));
nestedSection.setAttribute("data-app-action-sidebar-section", "recents");
const nestedRow = nestedSection.appendChild(element("button"));
nestedRow.setAttribute("data-app-action-sidebar-thread-row", "true");
const nestedContainers = layout.nativeListContainers([nestedRow], []);
assert.equal(nestedContainers.length, 1, "the nested native list must have one hideable container");
assert.equal(nestedContainers[0], nestedContents, "unrelated pinned controls must stay outside the hideable list container");
assert.ok(nestedOuter.contains(pinnedControl));
nestedNav.remove();

// Some builds use an aside rather than a nav around the scroll root. Multiple
// direct native sections must anchor to their own shared parent in that shape.
const aside = document.body.appendChild(element("aside"));
const asideScroll = aside.appendChild(element("div"));
asideScroll.setAttribute("data-app-action-sidebar-scroll", "true");
const asideProjectsWrapper = asideScroll.appendChild(element("div"));
const asideProjects = asideProjectsWrapper.appendChild(element("section"));
asideProjects.setAttribute("data-app-action-sidebar-section", "projects");
const asideProject = asideProjects.appendChild(nativeProject("aside-project", false));
const asideRecentsWrapper = asideScroll.appendChild(element("div"));
const asideRecents = asideRecentsWrapper.appendChild(element("section"));
asideRecents.setAttribute("data-app-action-sidebar-section", "recents");
const asideRow = asideRecents.appendChild(element("button"));
asideRow.setAttribute("data-app-action-sidebar-thread-row", "true");
layout.state.view = "native";
layout.useModel({ rows: [asideRow], nativeProjectItems: [asideProject], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.equal(layout.state.mountAnchor, asideScroll, "an aside-based multi-section layout must use its own scroll root as the mount anchor");
assert.equal(layout.state.panel.parentElement, asideScroll);
aside.remove();
layout.state.view = "mobile";

nativeContainer.append(projectsWrapper, recentsWrapper);
sidebarScroll.appendChild(nativeContainer);
layout.useModel({ rows: [nativeRecentRow], nativeProjectItems: [opened, closed], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.equal(layout.state.nativeContainer, nativeContainer, "the renderer must adopt the native list when React finishes loading it");
assert.equal(layout.state.mountAnchor, nativeContainer, "readiness must follow the discovered native list after reanchoring");
assert.equal(sidebarScroll.children.indexOf(layout.state.panel), sidebarScroll.children.indexOf(nativeContainer) - 1, "the panel must reanchor directly before the late native list");

nativeContainer.remove();
layout.useModel({ rows: [], nativeProjectItems: [], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.notEqual(nativeContainer.style.display, "none", "a temporarily detached native list must have its Mobile-mode hiding restored before state forgets it");
sidebarScroll.appendChild(nativeContainer);
layout.useModel({ rows: [nativeRecentRow], nativeProjectItems: [opened, closed], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.equal(nativeContainer.style.display, "none", "a reinserted native list must be hidden again in Mobile projects mode");
layout.state.view = "native";
layout.render();
assert.notEqual(nativeContainer.style.display, "none", "switching to Native sidebar after same-node reinsertion must restore its original display");

// A cached search model can retain a native row for less than one frame after
// React detaches it. Ignore that stale marker and keep the proven live mount.
const detachedCachedRow = recentsSection.appendChild(element("button"));
detachedCachedRow.setAttribute("data-app-action-sidebar-thread-row", "true");
detachedCachedRow.remove();
layout.useModel({ rows: [detachedCachedRow], nativeProjectItems: [], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.equal(layout.state.mountAnchor, nativeContainer, "a detached cached row must not clear a still-valid live native-list mount");
assert.equal(layout.state.panel.isConnected, true, "a transient detached cached row must not drop search focus by removing the panel");

layout.state.view = "mobile";
layout.state.localRuntime = { requestClient: { sendRequest: async () => ({}) } };
layout.useModel({
  rows: [nativeRecentRow], nativeProjectItems: [opened, closed],
  hosts: [
    { id: `${aliasEnvironmentPrefix}fixture_zulu`, name: "Zulu Desktop", available: true, availabilityKnown: true },
    { id: "local", name: "Fixture Desktop", available: true, availabilityKnown: true },
    { id: `${aliasEnvironmentPrefix}fixture_alpha`, name: "alpha Desktop", available: true, availabilityKnown: true },
    { id: `${aliasEnvironmentPrefix}fixture_ten`, name: "Peer 10", available: true, availabilityKnown: true },
    { id: `${aliasEnvironmentPrefix}fixture_two`, name: "Peer 2", available: true, availabilityKnown: true },
  ], remoteRuntimes: [],
  projects: [project("empty-open"), project("empty-closed")],
  recents: [{ key: "fixture-recent", kind: "recent", hostId: "local", hostName: "Fixture Desktop", name: "Recent chats", tasks: [{ ...task, statusType: "loading" }] }],
});
layout.render();
while (microtasks.length) microtasks.shift()();
updateControl = layout.state.panel.querySelector(".crmp-update-control");
assert.equal(updateControl.textContent, "Update available · v1.5.33", "the update control must remain visible in Mobile projects");
const filterChips = layout.state.panel.querySelectorAll(".crmp-chip");
assert.deepEqual(filterChips.map((chip) => chip.textContent), ["All", "This device", "alpha Desktop", "Bravo Alias", "Peer 2", "Peer 10"], "filters must show All, this device, then friendly remote names and saved aliases in case-insensitive natural order");
assert.equal(filterChips[0].getAttribute("aria-label"), "All devices");
assert.equal(filterChips[1].getAttribute("aria-label"), "This device, Fixture Desktop", "the current device's verified host name remains available to assistive technology");
const panelChildren = [...layout.state.panel.children];
const replacementCount = layout.state.panel.replaceChildrenCalls;
const renderSkipCount = layout.state.counters.panelRenderSkips;
layout.render();
while (microtasks.length) microtasks.shift()();
assert.equal(layout.state.panel.replaceChildrenCalls, replacementCount, "an unchanged internal refresh must not replace the visible sidebar tree");
assert.equal(layout.state.panel.children.length, panelChildren.length);
assert.ok(layout.state.panel.children.every((child, index) => child === panelChildren[index]), "an unchanged refresh must preserve every rendered sidebar node identity");
assert.equal(layout.state.counters.panelRenderSkips, renderSkipCount + 1, "the renderer must record a semantic no-op instead of redrawing unchanged content");
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
assert.ok(recentGroup.querySelector('.crmp-task-action[aria-label="Archive chat"]'), "a synthetic local row must expose the direct Archive chat action when its app-server runtime is available");
const archiveRuntime = layout.state.localRuntime;
layout.state.localRuntime = null;
layout.render();
assert.equal(layout.state.panel.querySelector('.crmp-task-action[aria-label="Archive chat"]'), null, "a synthetic row must not advertise direct archive when no current app-server runtime exists");
layout.state.localRuntime = archiveRuntime;
layout.render();
layout.state.pendingDirectArchives.set(`local::${task.conversationId}`, Promise.resolve(true));
layout.render();
const pendingArchiveButton = layout.state.panel.querySelector('.crmp-task-action[aria-label="Archive chat"]');
assert.equal(pendingArchiveButton.disabled, true, "an in-flight direct archive must disable repeated activation");
assert.equal(pendingArchiveButton.getAttribute("aria-busy"), "true", "an in-flight direct archive must expose accessible pending state");
layout.state.pendingDirectArchives.clear();
layout.render();
assert.equal(recentGroup.querySelector(".crmp-project-head"), null, "a single recent-task group must not add a synthetic folder absent from native Recents");
assert.equal(nativeContainer.style.display, "none", "Mobile projects must replace both native sections together");
layout.state.view = "native";
layout.render();
assert.notEqual(nativeContainer.style.display, "none", "switching back must restore the native container display");

// Refreshing a known empty inventory must keep its authoritative empty label
// and preserve the rendered nodes. Initial, stale, failed, disconnected and
// incomplete inventories must retain their distinct non-authoritative states.
const boundaryHost = `${aliasEnvironmentPrefix}refresh_boundaries`;
const freshEmptyInventory = {
  error: null,
  fetchedAt: Date.now(),
  generatedAt: Date.now(),
  pending: false,
  projects: [],
  tasks: new Map(),
  threads: [],
  threadsAuthoritative: true,
};
layout.state.displayedHosts = [
  { id: "local", name: "Fixture Desktop", available: true, availabilityKnown: true },
  { id: boundaryHost, name: "Boundary device", available: true, availabilityKnown: true },
];
layout.state.threadInventories.delete("local");
layout.state.inventoryHydrationPending = true;
layout.state.inventoryHydrationError = null;
assert.equal(layout.emptyInventoryMessage("local"), "Loading local tasks. Waiting for current inventory.", "initial local hydration must remain visibly non-authoritative");
layout.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), threads: [], truncated: false });
assert.equal(layout.emptyInventoryMessage("local"), "No chats", "a known authoritative local empty result must remain stable while refresh is pending");
layout.state.inventoryHydrationError = "fixture failure";
assert.equal(layout.emptyInventoryMessage("local"), "Loading local tasks. Waiting for current inventory.", "a global hydration failure must outrank an older healthy local inventory");
layout.state.inventoryHydrationError = null;
layout.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), threads: [], truncated: true });
assert.equal(layout.emptyInventoryMessage("local"), "Loading local tasks. Waiting for current inventory.", "a truncated local inventory must not be presented as authoritative");
layout.state.threadInventories.set("local", { error: "fixture failure", fetchedAt: Date.now(), threads: [], truncated: false });
assert.equal(layout.emptyInventoryMessage("local"), "Loading local tasks. Waiting for current inventory.", "a failed local inventory must not be presented as authoritative");

layout.state.remoteProjectInventories.delete(boundaryHost);
assert.equal(layout.emptyInventoryMessage(boundaryHost), "Loading tasks from this device…", "an initial remote load must remain visibly pending");
layout.state.remoteProjectInventories.set(boundaryHost, { ...freshEmptyInventory, pending: true });
assert.equal(layout.emptyInventoryMessage(boundaryHost), "No chats", "a fresh authoritative remote empty result must remain stable while refresh is pending");
assert.equal(layout.emptyInventoryMessage(boundaryHost, true), "No projects or tasks match this device. Choose All to see other devices.");
layout.state.remoteProjectInventories.set(boundaryHost, { ...freshEmptyInventory, fetchedAt: Date.now() - 600000, generatedAt: Date.now() - 600000, pending: true });
assert.equal(layout.emptyInventoryMessage(boundaryHost), "Task information is out of date. Waiting for the device to refresh.", "a stale pending inventory must not borrow an authoritative empty label");
layout.state.threadInventories.set(boundaryHost, { error: null, fetchedAt: Date.now(), threads: [], truncated: false });
layout.state.localRegisteredProjectsFetchedAt = Date.now() - 16000;
layout.state.localRegisteredProjectsPending = true;
assert.equal(layout.emptyInventoryMessage(boundaryHost), "No chats", "a fresh direct Codex task list must outrank stale optional peer inventory");
assert.equal(layout.inventoryLabel(boundaryHost), "Current project catalog and task membership read directly through Codex.");
assert.equal(layout.freshDirectDeviceInventory(boundaryHost).fetchedAt, layout.state.localRegisteredProjectsFetchedAt,
  "combined direct-inventory age must report the older required catalog evidence");
layout.state.localRegisteredProjectsFetchedAt = Date.now() - 181000;
assert.equal(layout.emptyInventoryMessage(boundaryHost), "Task information is out of date. Waiting for the device to refresh.", "the native project catalog must expire at the authority boundary, not the refresh cadence");
layout.state.localRegisteredProjectsFetchedAt = Date.now();
layout.state.localRegisteredProjectsError = "fixture catalog failure";
assert.equal(layout.emptyInventoryMessage(boundaryHost), "No chats", "a recent successful catalog must stay authoritative during a transient refresh error");
assert.equal(layout.inventoryLabel(boundaryHost), "Current project catalog and task membership read directly through Codex.");
layout.state.localRegisteredProjectsError = null;
layout.state.localRegisteredProjectsPending = false;
layout.state.threadInventories.delete(boundaryHost);
layout.state.remoteProjectInventories.set(boundaryHost, { ...freshEmptyInventory, error: "fixture failure", pending: true });
assert.equal(layout.emptyInventoryMessage(boundaryHost), "Task information is out of date. Waiting for the device to refresh.", "a failed pending inventory must retain its failure boundary");
layout.state.displayedHosts[1].available = false;
assert.equal(layout.emptyInventoryMessage(boundaryHost), "Device disconnected. Reconnect it using Remote to load tasks.", "disconnection must outrank retained inventory");
layout.state.displayedHosts[1].available = true;
layout.state.remoteProjectInventories.set(boundaryHost, { ...freshEmptyInventory, pending: true, threadsAuthoritative: false });
assert.equal(layout.emptyInventoryMessage(boundaryHost), "Waiting for a complete task inventory.", "an incomplete pending inventory must not appear authoritatively empty");

layout.state.threadInventories.set("local", { error: null, fetchedAt: Date.now(), threads: [], truncated: false });
layout.state.inventoryHydrationPending = false;
layout.state.inventoryHydrationError = null;
layout.state.remoteProjectInventories.set(boundaryHost, { ...freshEmptyInventory });
layout.state.settingsOpen = false;
layout.state.filter = "all";
layout.state.view = "mobile";
const refreshModel = {
  rows: [], nativeProjectItems: [opened],
  hosts: layout.state.displayedHosts, remoteRuntimes: new Map(),
  projects: [project("empty-open"), { ...project("remote-empty"), key: `${boundaryHost}:remote-empty`, hostId: boundaryHost, hostName: "Boundary device", projectId: null, cwd: "/fixture/remote-empty" }],
  recents: [],
};
layout.useModel(refreshModel);
layout.state.threadInventories.set(boundaryHost, { error: null, fetchedAt: Date.now(), threads: [], truncated: false });
layout.state.remoteProjectInventories.set(boundaryHost, { ...freshEmptyInventory, error: "older helper publisher unavailable", fetchedAt: Date.now() - 600000, generatedAt: Date.now() - 600000 });
layout.state.deviceRefreshLastSuccessfulAt = Date.now();
layout.render();
assert.equal(layout.state.panel.querySelector(".crmp-sync-status")?.dataset.state, "ready", "fresh direct task membership must clear the stale-device banner");
assert.equal(layout.state.panel.querySelector(".crmp-sync-status")?.textContent, "Device data is up to date.");
assert.equal(layout.state.panel.querySelector(".crmp-inventory-status"), null, "fresh direct project and task data must suppress an older helper failure banner");
layout.state.taskActionFeedback = "Could not archive //NAS/Data\\Backups\\Infrastructure: archive refused";
layout.render();
assert.equal(layout.state.panel.querySelector(".crmp-sync-status")?.dataset.state, "error", "task action failures must use the visible error status");
assert.ok(layout.state.panel.querySelector(".crmp-sync-status")?.textContent.startsWith(layout.state.taskActionFeedback), "archive failure details must remain visible to the user");
assert.ok(layout.state.panel.querySelector(".crmp-sync-details"), "archive feedback must not hide the Device health entry point");
layout.state.taskActionFeedback = null;
layout.render();
const refreshChildren = [...layout.state.panel.children];
const refreshReplacementCount = layout.state.panel.replaceChildrenCalls;
const refreshSkipCount = layout.state.counters.panelRenderSkips;
layout.state.inventoryHydrationPending = true;
layout.state.remoteProjectInventories.set(boundaryHost, { ...freshEmptyInventory, error: "older helper publisher unavailable", fetchedAt: Date.now() - 600000, generatedAt: Date.now() - 600000, pending: true });
layout.render();
assert.deepEqual(layout.state.panel.querySelectorAll(".crmp-empty-project-message").map((item) => item.textContent), ["No chats", "No chats"], "a pending refresh must retain both known authoritative empty labels");
assert.equal(layout.state.panel.replaceChildrenCalls, refreshReplacementCount, "a pending refresh with unchanged authoritative empty results must not replace the panel");
assert.ok(layout.state.panel.children.every((child, index) => child === refreshChildren[index]), "the pending refresh must retain rendered node identity");
assert.equal(layout.state.counters.panelRenderSkips, refreshSkipCount + 1, "the real render path must classify a known-empty refresh as a semantic no-op");

const legacyContainer = nav.appendChild(element("div", "legacy-native-list"));
const legacyRow = legacyContainer.appendChild(element("button"));
legacyRow.setAttribute("data-app-action-sidebar-thread-row", "true");
assert.equal(layout.nativeListContainer([legacyRow], []), legacyContainer, "legacy sectionless lists must retain their safe common ancestor");
assert.equal(layout.nativeListContainers([legacyRow], []).length, 0, "a populated legacy list plus modern marked sections must fail closed as mixed ownership");
layout.useModel({ rows: [legacyRow], nativeProjectItems: [], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.equal(layout.state.mountAnchor, null, "mixed row and section ownership must clear readiness instead of mounting a partial replacement");
assert.equal(layout.state.panel.isConnected, false);
const unsafeSection = nav.appendChild(element("section"));
const unsafeRow = unsafeSection.appendChild(element("button"));
unsafeRow.setAttribute("data-app-action-sidebar-thread-row", "true");
unsafeSection.appendChild(element("button", "", "Explore"));
assert.equal(layout.nativeListContainer([unsafeRow], []), null, "a section containing global navigation must never become the replacement mount");
const otherSection = nav.appendChild(element("section"));
const otherRow = otherSection.appendChild(element("button"));
otherRow.setAttribute("data-app-action-sidebar-thread-row", "true");
assert.equal(layout.nativeListContainer([legacyRow, otherRow], []), null, "a nav/body fallback must never hide the entire sidebar shell");

// Rows in an unrecognized shell must fail readiness rather than mounting below
// and duplicating the complete native list or retaining an earlier ready mount.
const unsafeScroll = nav.appendChild(element("div"));
unsafeScroll.setAttribute("data-app-action-sidebar-scroll", "true");
const unsafeShell = unsafeScroll.appendChild(element("div"));
unsafeShell.appendChild(element("button", "", "New chat"));
const unsafeLegacyRow = unsafeShell.appendChild(element("button"));
unsafeLegacyRow.setAttribute("data-app-action-sidebar-thread-row", "true");
layout.useModel({ rows: [unsafeLegacyRow], nativeProjectItems: [], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.equal(layout.state.mountAnchor, null, "an unsafe populated layout must clear stale readiness");
assert.equal(layout.state.panel.isConnected, false, "an unsafe populated layout must not mount below the duplicated native list");
unsafeScroll.remove();

// Older builds expose stable native section markers inside nav without the
// newer scroll capability. Preserve that exact list as the mount anchor.
sidebarScroll.removeAttribute("data-app-action-sidebar-scroll");
layout.useModel({ rows: [], nativeProjectItems: [], hosts: [], remoteRuntimes: [], projects: [], recents: [] });
layout.render();
assert.equal(layout.state.nativeContainer, nativeContainer, "legacy empty sections without a scroll marker must remain discoverable");
assert.equal(layout.state.mountAnchor, nativeContainer, "legacy empty-section readiness must follow the proven native list");
assert.equal(layout.state.panel.parentElement, sidebarScroll, "the legacy panel must mount directly before the proven native list");
sidebarScroll.setAttribute("data-app-action-sidebar-scroll", "true");

// Missing native rows still receive a useful empty state, without borrowing
// project names, host IDs or stale native task content.
nativeContainer.remove();
const remoteEmpty = element("div", "crmp-tasks");
layout.appendEmptyProjectState(remoteEmpty, { ...project("unregistered"), hostId: "fixture-peer" });
assert.equal(remoteEmpty.textContent, "Loading tasks from this device…", "missing remote inventory must not be represented as an authoritative empty project");
for (const name of ["text-codex-description", "opacity-50", "px-8", "py-1", "text-base"]) {
  assert.ok(remoteEmpty.querySelector(".crmp-empty-project-message")?.classList.contains(name), `missing inventories must retain native ${name} geometry and typography`);
}

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
