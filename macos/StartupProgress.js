// Copyright (c) 2026 Clean-room contributors
//
// This is a small AppKit progress worker for the per-user Dock shortcut.  It
// only observes the launcher's private state file; it never sends Apple Events
// to ChatGPT/Codex and never starts or stops either desktop application.

"use strict";

ObjC.import("Cocoa");
ObjC.import("Foundation");
ObjC.bindFunction("kill", ["int", ["int", "int"]]);

const WINDOW_TITLE = "ChatGPT Remote Enabler";
const PROGRESS_ROOT_SUFFIX = "/Library/Application Support/CodexRemoteFeatures/startup-progress/";
const STAGE_INDEX = Object.freeze({
  starting: 0,
  "update-recovery": 1,
  "update-check": 2,
  maintenance: 3,
  launch: 4,
  "renderer-readiness": 5,
  complete: 5,
});

function cleanText(value, fallback = "") {
  const text = String(value ?? "").replace(/[\r\n\0]+/gu, " ").replace(/[\t]+/gu, " ").trim();
  return text || fallback;
}

function parseArguments(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = String(argv[index]);
    if (argument === "--state" || argument === "--owner") {
      if (index + 1 >= argv.length) throw new Error(`${argument} requires a value.`);
      result[argument.slice(2)] = String(argv[++index]);
    } else if (argument === "--mode") {
      if (index + 1 >= argv.length) throw new Error("--mode requires a value.");
      result.mode = String(argv[++index]);
    } else {
      throw new Error(`Unsupported startup-progress argument: ${argument}`);
    }
  }
  return result;
}

function assertStatePath(statePath) {
  const home = String(ObjC.unwrap($.NSHomeDirectory()));
  const root = `${home}${PROGRESS_ROOT_SUFFIX}`;
  if (!statePath || !statePath.startsWith(root) || !statePath.endsWith(".status") ||
      statePath.includes("\n") || statePath.includes("\r") || statePath.includes("\0") || statePath.includes("..")) {
    throw new Error("The startup progress state path is outside the private per-user directory.");
  }
  return statePath;
}

function readState(statePath) {
  try {
    const value = $.NSString.stringWithContentsOfFileEncodingError(statePath, $.NSUTF8StringEncoding, null);
    if (!value) return null;
    const text = String(ObjC.unwrap(value));
    const line = text.split(/\r?\n/u).find((candidate) => candidate.length > 0);
    if (!line) return null;
    const separator = line.indexOf("\t");
    const kind = cleanText(separator < 0 ? line : line.slice(0, separator));
    const message = cleanText(separator < 0 ? "" : line.slice(separator + 1));
    return kind ? { kind, message } : null;
  } catch {
    return null;
  }
}

function ownerIsAlive(ownerPid) {
  try {
    const result = Number($.kill(Number(ownerPid), 0));
    if (result === 0) return true;
    return Number($.__error()[0]) === 1; // EPERM: the same-user owner is alive but protected.
  } catch {
    return false;
  }
}

function removeState(statePath) {
  try { $.NSFileManager.defaultManager.removeItemAtPathError(statePath, null); } catch {}
  try { $.NSFileManager.defaultManager.removeItemAtPathError(`${statePath}.ready`, null); } catch {}
}

function acknowledgeReady(statePath) {
  const readyPath = `${statePath}.ready`;
  const value = $.NSString.stringWithString("ready\n");
  if (!value.writeToFileAtomicallyEncodingError(readyPath, true, $.NSUTF8StringEncoding, null)) {
    throw new Error("The startup progress helper could not acknowledge readiness.");
  }
}

function labelWithFrame(frame, text, size) {
  const label = $.NSTextField.alloc.initWithFrame(frame);
  label.stringValue = text;
  label.bezeled = false;
  label.drawsBackground = false;
  label.editable = false;
  label.selectable = false;
  label.font = $.NSFont.systemFontOfSize(size);
  return label;
}

function run(argv) {
  const argumentsValue = parseArguments(argv);
  const ownerPid = Number(argumentsValue.owner);
  if (!Number.isSafeInteger(ownerPid) || ownerPid <= 0) throw new Error("The startup progress owner is invalid.");
  if (argumentsValue.mode === "self-test") {
    return JSON.stringify({ runtimeReady: true, ownerAlive: ownerIsAlive(ownerPid) });
  }
  if (argumentsValue.mode) throw new Error(`Unsupported startup-progress mode: ${argumentsValue.mode}`);
  const statePath = assertStatePath(argumentsValue.state);

  const application = $.NSApplication.sharedApplication;
  application.setActivationPolicy($.NSApplicationActivationPolicyRegular);
  const window = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, 520, 190),
    1 | 2 | 8, // titled | closable | miniaturizable
    $.NSBackingStoreBuffered,
    false,
  );
  window.title = WINDOW_TITLE;
  window.releasedWhenClosed = false;
  window.center;

  const content = window.contentView;
  const heading = labelWithFrame($.NSMakeRect(24, 142, 472, 28), WINDOW_TITLE, 18);
  const phase = labelWithFrame($.NSMakeRect(24, 108, 472, 28), "Starting…", 13);
  const detail = labelWithFrame($.NSMakeRect(24, 82, 472, 22), "Please keep this window open until ChatGPT is ready.", 11);
  detail.textColor = $.NSColor.secondaryLabelColor;
  const bar = $.NSProgressIndicator.alloc.initWithFrame($.NSMakeRect(24, 45, 472, 18));
  bar.indeterminate = false;
  bar.minValue = 0;
  bar.maxValue = 5;
  bar.doubleValue = 0;
  bar.controlSize = $.NSControlSizeRegular;
  const hint = labelWithFrame($.NSMakeRect(24, 14, 472, 22), "Remote Enabler is preparing a protected session.", 10);
  hint.textColor = $.NSColor.secondaryLabelColor;
  content.addSubview(heading);
  content.addSubview(phase);
  content.addSubview(detail);
  content.addSubview(bar);
  content.addSubview(hint);

  window.makeKeyAndOrderFront(null);
  application.activateIgnoringOtherApps(true);
  acknowledgeReady(statePath);

  let completeAt = 0;
  let errorShown = false;
  const applyState = (state) => {
    if (!state) return;
    const kind = state.kind;
    if (kind === "error") {
      errorShown = true;
      heading.stringValue = "ChatGPT Remote Enabler could not start";
      phase.stringValue = "Action required";
      detail.stringValue = cleanText(state.message, "Review the launcher log and try again.");
      detail.textColor = $.NSColor.systemRedColor;
      hint.stringValue = "No ChatGPT process was stopped. Close this window, correct the issue, and retry.";
      bar.doubleValue = 0;
      return;
    }
    const index = Object.prototype.hasOwnProperty.call(STAGE_INDEX, kind) ? STAGE_INDEX[kind] : null;
    if (index === null) return;
    const names = {
      starting: "Starting…",
      "update-recovery": "Recovering any interrupted update…",
      "update-check": "Checking and updating Remote Enabler…",
      maintenance: "Preparing local maintenance…",
      launch: "Launching ChatGPT with Remote enabled…",
      "renderer-readiness": "Waiting for renderer readiness…",
      complete: "ChatGPT Remote is ready.",
    };
    phase.stringValue = names[kind] || cleanText(state.message, "Working…");
    detail.stringValue = cleanText(state.message, "Please keep this window open until ChatGPT is ready.");
    detail.textColor = $.NSColor.labelColor;
    bar.doubleValue = index;
    if (kind === "complete") {
      heading.stringValue = "ChatGPT Remote Enabler is ready";
      hint.stringValue = "The protected session is ready. This window will close automatically.";
      if (completeAt === 0) completeAt = Date.now() + 700;
    }
  };

  for (;;) {
    if (!window.isVisible) {
      removeState(statePath);
      break;
    }
    const state = readState(statePath);
    if (state) applyState(state);
    else if (!ownerIsAlive(ownerPid) && !errorShown) {
      applyState({ kind: "error", message: "The launcher exited before it reported readiness. Review the launcher log and retry." });
    }
    if (completeAt > 0 && Date.now() >= completeAt) {
      window.close;
      removeState(statePath);
      break;
    }
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.2));
  }
  application.terminate(null);
}
