"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const rendererPath = path.join(__dirname, "..", "renderer-mobile-project-view.js");
const source = fs.readFileSync(rendererPath, "utf8");
const testSource = source.replace("(() => {", "globalThis.__sidebarStatusTest = (() => {")
  .replace("  return install();\n})();", "  return { aggregateSidebarStatus, ensureStyle, metadataFromRow, nativeProjectStatus, nativeTaskStatusMetadata, normalizeSidebarStatus, projectStatusIndicator, reserveTaskStatusSpace, sidebarStatusContent, sidebarStatusKind, sidebarStatusTemplate, taskSidebarStatus, taskStatusIndicator, taskStatusLabel };\n})();");

class FixtureElement {
  constructor(tagName = "div") {
    this.tagName = tagName.toUpperCase();
    this.attributes = new Map();
    this.children = [];
    this.style = {};
    this.dataset = {};
    this.className = "";
    this.innerHTML = "";
    this.ownText = "";
    this.parentElement = null;
    this.events = new Map();
    this.classList = {
      add: (...values) => { this.className = [...new Set([...this.className.split(/\s+/).filter(Boolean), ...values])].join(" "); },
      contains: value => this.className.split(/\s+/).includes(value),
    };
  }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  get textContent() { return this.ownText + this.children.map(child => child.textContent).join(""); }
  set textContent(value) { this.ownText = String(value); this.children = []; }
  appendChild(child) { this.children.push(child); child.parentElement = this; return child; }
  append(...children) { children.forEach(child => this.appendChild(child)); }
  addEventListener(name, callback) { this.events.set(name, callback); }
  contains(element) { return element === this || this.children.some(child => child.contains(element)); }
  matches(selector) {
    if (selector === "button" || selector === "span") return this.tagName === selector.toUpperCase();
    if (selector === '[class*="animate-spin"]') return this.className.includes("animate-spin");
    const attributes = [...selector.matchAll(/\[([^\]=]+)(?:="([^"]*)")?\]/g)];
    return attributes.length > 0 && attributes.every(([,name,value]) => value === undefined ? this.attributes.has(name) : this.getAttribute(name) === value);
  }
  querySelectorAll(selector) {
    const selectors = selector.split(",");
    return this.children.flatMap(child => [
      ...(selectors.some(value => child.matches(value)) ? [child] : []),
      ...child.querySelectorAll(selector),
    ]);
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
  closest(selector) {
    for (let element = this; element; element = element.parentElement) if (element.matches(selector)) return element;
    return null;
  }
  cloneNode(deep) {
    const clone = new FixtureElement(this.tagName);
    clone.className = this.className;
    clone.innerHTML = this.innerHTML;
    clone.ownText = this.ownText;
    clone.style = { ...this.style };
    clone.attributes = new Map(this.attributes);
    if (deep) this.children.forEach(child => clone.appendChild(child.cloneNode(true)));
    return clone;
  }
}

const projects = [];
const head = new FixtureElement("head");
const document = {
  head,
  createElement: tag => new FixtureElement(tag),
  getElementById: () => null,
  querySelectorAll: selector => selector === '[data-sidebar-project-kind][role="listitem"]' ? projects : [],
};
const context = vm.createContext({
  CSS: { escape: value => value },
  Element: FixtureElement,
  TextDecoder,
  TextEncoder,
  clearInterval,
  clearTimeout,
  console,
  crypto: { randomUUID: () => "sidebar-status-fixture" },
  document,
  getComputedStyle: element => element.style,
  globalThis: null,
  localStorage: { getItem: () => null, removeItem() {}, setItem() {} },
  setInterval,
  setTimeout,
});
context.globalThis = context;
vm.runInContext(testSource, context, { filename: rendererPath });
const sidebar = context.__sidebarStatusTest;
assert.ok(sidebar, "the fixture must expose renderer helpers without installing the renderer");
const plain = value => JSON.parse(JSON.stringify(value));
const loading = { statusType: "loading", unread: false };
const unread = { statusType: "idle", unread: true };
const idle = { statusType: "idle", unread: false };

assert.equal(sidebar.sidebarStatusKind({ type: "loading", unread: true, unreadCount: 3 }), "count", "native unread count must outrank running state");
assert.equal(sidebar.sidebarStatusKind({ type: "loading", unread: true }), "loading", "running must outrank the plain unread dot on a task");
assert.equal(sidebar.sidebarStatusKind({ type: "idle", unread: true }), "unread");
assert.equal(sidebar.sidebarStatusKind({ type: "error", unread: false }), "error");
assert.equal(sidebar.sidebarStatusKind({ type: "idle", unread: false }), null);
assert.equal(sidebar.normalizeSidebarStatus({ unreadCount: Infinity }).unreadCount, 0);
assert.equal(sidebar.normalizeSidebarStatus({ unreadCount: -2 }).unreadCount, 0);

assert.equal(sidebar.aggregateSidebarStatus([]), null);
assert.equal(sidebar.aggregateSidebarStatus([idle]), null);
assert.equal(sidebar.aggregateSidebarStatus([loading, idle]).type, "loading", "active-only folders show a spinner");
assert.equal(sidebar.aggregateSidebarStatus([loading, unread]).unread, true, "an unread descendant outranks running descendants on folders");
assert.equal(sidebar.aggregateSidebarStatus([{ ...loading, needsAttention: true }, loading]).unread, true, "waiting for attention outranks active descendants");
assert.equal(sidebar.aggregateSidebarStatus([{ ...idle, unreadCount: 4 }, loading]).unread, true, "folder aggregates use a dot rather than summing unread badges");
assert.equal(sidebar.aggregateSidebarStatus([{ ...loading, sourceThread: { status: { type: "active", activeFlags: ["waitingOnApproval"] } } }]).unread, true, "unmounted remote tasks preserve explicit approval flags");
assert.equal(sidebar.aggregateSidebarStatus([{ ...loading, sourceThread: { status: { type: "active", activeFlags: ["waitingOnUserInput"] } } }]).unread, true);
assert.equal(sidebar.aggregateSidebarStatus([{ ...idle, nativeStatusState: { type: "error" } }]), null, "native folder aggregation does not invent an error aggregate");

function taskRow(statusState, owner = {}) {
  const row = new FixtureElement();
  row.setAttribute("data-app-action-sidebar-thread-id", "local:11111111-1111-4111-8111-111111111111");
  row.setAttribute("data-app-action-sidebar-thread-title", "Status fixture");
  row.setAttribute("data-app-action-sidebar-thread-host-id", "local");
  row.setAttribute("data-app-action-sidebar-thread-selected", "false");
  row.__reactFiber$fixture = {
    memoizedProps: {},
    return: {
      memoizedProps: statusState === undefined ? {} : { statusState },
      return: {
        memoizedProps: { conversationId: "11111111-1111-4111-8111-111111111111", ...owner },
        return: { memoizedProps: { statusState: { type: "loading", unread: true, unreadCount: 99 }, isUnread: true }, return: null },
      },
    },
  };
  return row;
}

const idleRow = taskRow({ type: "idle", unread: false, unreadCount: 0 });
const rowMetadata = sidebar.metadataFromRow(idleRow);
assert.equal(rowMetadata.statusType, "idle", "ancestor folder loading state must not contaminate an idle task");
assert.equal(rowMetadata.unread, false, "ancestor unread state must not contaminate a read task");
assert.equal(rowMetadata.unreadCount, 0);
assert.equal(sidebar.metadataFromRow(taskRow(undefined, { isUnread: false })).unread, false, "the nearest task unread=false must stop fallback traversal");
assert.equal(sidebar.metadataFromRow(taskRow(undefined, { isUnread: true })).unread, true);
const countRow = taskRow({ type: "loading", unread: true, unreadCount: 4 });
assert.equal(sidebar.metadataFromRow(countRow).unreadCount, 4);
const approvalRow = taskRow({ type: "loading", unread: false }, { hasPendingChildApproval: true });
assert.equal(sidebar.metadataFromRow(approvalRow).needsAttention, true);
assert.equal(sidebar.taskStatusLabel(sidebar.metadataFromRow(approvalRow)), "Awaiting approval");
assert.equal(sidebar.taskSidebarStatus({ ...idle, nativeStatusState: { type: "loading" } }).type, "idle", "authoritative completed inventory must still replace stale native loading");

const fallbackSpinner = sidebar.taskStatusIndicator(loading);
assert.ok(fallbackSpinner.classList.contains("crmp-task-status-loading"));
const spinner = fallbackSpinner.children[0].children[0];
assert.ok(spinner.classList.contains("crmp-status-spin"));
assert.equal(spinner.style.animationDuration, "2000ms");
assert.match(spinner.style.animationDelay, /^-\d+ms$/);
assert.match(spinner.innerHTML, /M12 4C16\.4183 4 20 7\.58172 20 12/, "fallback must use the native spinner shape");
assert.equal(fallbackSpinner.getAttribute("aria-hidden"), "true");
assert.equal(sidebar.taskStatusIndicator(idle), null);
const fallbackCount = sidebar.taskStatusIndicator({ ...loading, unreadCount: 140 });
assert.ok(fallbackCount.classList.contains("crmp-task-status-count"));
assert.equal(fallbackCount.textContent, "99+");
const inputRow = new FixtureElement();
const inputPill = new FixtureElement("button");
inputPill.className = "relative inline-grid rounded-full bg-chart-blue/15";
for (let index = 0; index < 2; index += 1) {
  const label = new FixtureElement("span");
  label.textContent = "Needs input";
  inputPill.appendChild(label);
}
inputRow.appendChild(inputPill);
const inputStatus = sidebar.taskStatusIndicator({ ...idle, originalRow: inputRow, attentionKind: "input", attentionLabel: "Needs input", needsAttention: true });
assert.ok(inputStatus.classList.contains("crmp-task-status-attention"));
assert.equal(inputStatus.children[0].tagName, "BUTTON", "the complete native input pill, including its hidden hover label, must survive cloning");
assert.equal(inputStatus.children[0].className, inputPill.className);
assert.notEqual(inputStatus.children[0], inputPill);
assert.equal(inputStatus.getAttribute("aria-hidden"), null, "an actionable input pill must remain accessible");
assert.ok(inputStatus.children[0].events.has("click"), "the cloned input control must replay its native action");
const inputFallback = sidebar.taskStatusIndicator({ ...loading, sourceThread: { status: { type: "active", activeFlags: ["waitingOnUserInput"] } } });
assert.ok(inputFallback.classList.contains("crmp-task-status-attention"));
assert.equal(inputFallback.textContent, "Needs input");
const errorFallback = sidebar.taskStatusIndicator({ ...idle, nativeStatusState: { type: "error" } });
assert.match(errorFallback.children[0].innerHTML, /M8 1\.48633C11\.5972/, "fallback error must use the native circle-info asset");
const longTitle = new FixtureElement("button");
longTitle.textContent = "A long task title alongside a Needs input control";
longTitle.style.paddingRight = "56px";
longTitle.isConnected = true;
inputStatus.isConnected = true;
inputStatus.style.right = "8px";
inputStatus.getBoundingClientRect = () => ({ width: 127.5 });
sidebar.reserveTaskStatusSpace(longTitle, inputStatus);
assert.equal(longTitle.style.paddingRight, "139px", "reserve measured attention width plus native inset and text gap");
longTitle.style.paddingRight = "56px";
fallbackSpinner.isConnected = true;
fallbackSpinner.style.right = "8px";
fallbackSpinner.getBoundingClientRect = () => ({ width: 20 });
sidebar.reserveTaskStatusSpace(longTitle, fallbackSpinner);
assert.equal(longTitle.style.paddingRight, "56px", "a spinner must keep the existing hover-action reserve");
inputStatus.isConnected = false;
sidebar.reserveTaskStatusSpace(longTitle, inputStatus);
assert.equal(longTitle.style.paddingRight, "56px", "queued spacing work must ignore a row removed by a newer render");

// A native status component may contain a wrapper above its spinner SVG. Clone the
// complete subtree so native timing, count/dot treatment, and classes survive.
const templateRoot = new FixtureElement();
const nativeContent = new FixtureElement();
const nativeSpin = new FixtureElement();
nativeSpin.className = "motion-safe:animate-spin";
nativeSpin.style.animationDuration = "2000ms";
nativeSpin.appendChild(new FixtureElement("svg"));
nativeContent.appendChild(nativeSpin);
templateRoot.appendChild(nativeContent);
templateRoot.__reactFiber$fixture = {
  memoizedProps: {},
  child: { memoizedProps: { statusState: { type: "loading" } }, child: { stateNode: nativeContent } },
};
const cloned = sidebar.sidebarStatusContent({ type: "loading" }, templateRoot);
assert.notEqual(cloned, nativeContent);
assert.equal(cloned.children[0].children[0].tagName, "SVG");
assert.ok(cloned.children[0].classList.contains("crmp-status-spin"));
assert.equal(cloned.children[0].style.animationDuration, "2000ms");
assert.equal(nativeSpin.classList.contains("crmp-status-spin"), false, "cloning must not mutate the native template");
assert.equal(sidebar.sidebarStatusTemplate(templateRoot, { type: "idle", unread: true }), null, "a stale native spinner must not be cloned for an unread state");

const project = { kind: "project", projectId: "fixture-project", hostId: "local", name: "Status fixture", tasks: [] };
const projectItem = new FixtureElement();
projectItem.setAttribute("data-sidebar-project-kind", "local");
projectItem.setAttribute("role", "listitem");
projectItem.setAttribute("data-app-action-sidebar-project-list-id", project.projectId);
const projectHeader = new FixtureElement();
projectHeader.setAttribute("data-app-action-sidebar-project-row", "");
projectHeader.setAttribute("data-app-action-sidebar-project-collapsed", "true");
projectHeader.__reactFiber$fixture = {
  memoizedProps: {},
  return: { memoizedProps: { actions: { props: { collapsedStatusState: { type: "loading" } } } } },
};
projectItem.appendChild(projectHeader);
projects.push(projectItem);
const collapsedStatus = sidebar.nativeProjectStatus(project);
assert.equal(collapsedStatus.known, true);
assert.equal(collapsedStatus.statusState.type, "loading");
assert.equal(project.tasks.length, 0);
assert.ok(sidebar.projectStatusIndicator(project, false).classList.contains("crmp-project-status-loading"), "collapsed native aggregate must survive completely unmounted task rows");
assert.equal(sidebar.projectStatusIndicator(project, true), null, "expanded folders suppress their aggregate status");
assert.equal(sidebar.projectStatusIndicator({ ...project, flatRecent: true }, false), null);
projectHeader.__reactFiber$fixture.return.memoizedProps.actions.props.collapsedStatusState = { type: "idle", unread: true };
assert.ok(sidebar.projectStatusIndicator({ ...project, tasks: [loading] }, false).classList.contains("crmp-project-status-unread"), "the full native aggregate outranks partial visible child inventory");
projectHeader.__reactFiber$fixture.return.memoizedProps.actions.props.collapsedStatusState = null;
assert.equal(sidebar.projectStatusIndicator({ ...project, tasks: [loading] }, false), null, "known native empty status must clear a stale fallback spinner");
projects.length = 0;
assert.ok(sidebar.projectStatusIndicator({ ...project, tasks: [loading] }, false).classList.contains("crmp-project-status-loading"), "inventory-only folders compute their own aggregate");

sidebar.ensureStyle();
const stylesheet = head.children[0].textContent;
assert.match(stylesheet, /@media \(prefers-reduced-motion:no-preference\)[^\n]+crmp-status-spin[^\n]+2000ms linear infinite/);
assert.match(stylesheet, /@media \(prefers-reduced-motion:reduce\)[^\n]+crmp-status-spin[^\n]+animation:none!important/);
assert.doesNotMatch(stylesheet, /850ms/);
assert.match(stylesheet, /crmp-project-head\[data-actions-open="true"\] \.crmp-project-status \{ visibility:hidden/);
assert.deepEqual(plain(sidebar.normalizeSidebarStatus({ type: "loading", unread: true, unreadCount: 3 })), { type: "loading", unread: true, unreadCount: 3 });

console.log("Sidebar status self-test passed (task priority, attention, collapsed aggregation, unmounted rows, native cloning, animation, and reduced motion).");
