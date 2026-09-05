"use strict";

// Optional real-browser integration suite. Supply Playwright through NODE_PATH
// and, when required, CHATGPT_REMOTE_BROWSER with a Chromium executable path.
// No real app, account, peer, updater, or native command is contacted.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");

const sourcePath = path.join(__dirname, "..", "windows", "CodexRemoteMobileProject", "renderer-mobile-project-view.js");
const source = fs.readFileSync(sourcePath, "utf8").replace(/\r\n/gu, "\n");
const fixtureSource = source.replace("  return install();\n})();", "  globalThis.__crmpBrowserFixture = { state, install, render, collectModel, emptyInventoryMessage, refreshDeviceHealth, diagnosticSnapshot };\n})();");
assert.notEqual(fixtureSource, source, "The fixture must expose the real renderer entrypoints.");

async function main() {
    const screenshotIndex = process.argv.indexOf("--screenshot");
    const screenshotPath = screenshotIndex >= 0 ? path.resolve(process.argv[screenshotIndex + 1]) : null;

  const defaultEdge = process.platform === "win32" ? path.join(process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)", "Microsoft", "Edge", "Application", "msedge.exe") : null;
  const executablePath = process.env.CHATGPT_REMOTE_BROWSER || (defaultEdge && fs.existsSync(defaultEdge) ? defaultEdge : undefined);
  const browser = await chromium.launch({ executablePath, headless: true });
  const errors = [];
  try {
    const page = await browser.newPage({ viewport: { width: 820, height: 760 } });
    page.setDefaultTimeout(6000);
    page.on("pageerror", error => errors.push(error.message));
    await page.route("http://renderer-fixture.invalid/**", route => route.fulfill({ contentType: "text/html", body: `<!doctype html><html><head><style>
      :root { color-scheme:dark } * { box-sizing:border-box } body { margin:0; background:#151a24; color:#e5e7eb; font:13px Arial,sans-serif }
      nav { width:288px; min-height:760px; padding:8px; background:#1b222f; border-right:1px solid #354052 }
      button { color:inherit; font:inherit; background:transparent; border:0; cursor:pointer } .global { display:block; padding:12px 8px; width:100%; text-align:left }
      #outside { position:absolute; top:36px; left:330px; color:#9ca3af } #native-list { margin-top:20px }
      [role=listitem] { padding:6px } [data-app-action-sidebar-project-collapsed] { padding:6px }
    </style></head><body><nav><button class="global">New chat</button><button class="global">Pull requests</button><button class="global">Scheduled</button><button class="global">Plugins</button><button class="global">Explore</button><button aria-label="Project sidebar options" hidden></button><div id="native-list"><div id="native-project" data-sidebar-project-kind="remote" role="listitem"><div role="button" tabindex="0" aria-expanded="true" data-app-action-sidebar-project-collapsed="false">Design project</div></div></div></nav><div id="outside">Renderer integration fixture</div></body></html>` }));
    await page.goto("http://renderer-fixture.invalid/");
    await page.evaluate(() => {
      globalThis.__fixtureHost = "remote-control:" + "env" + "_" + "primary_fixture";
      globalThis.__fixtureOlderHost = "remote-control:" + "env" + "_" + "older_fixture";
      globalThis.__CODEX_REMOTE_MOBILE_CONFIG__ = { localDisplayName: "Local device", helperVersion: "v1.5.35", hostDisplayNames: {} };
      localStorage.setItem("codex-remote-mobile-auto-register-enabled-v1", "false");
      localStorage.setItem("codex-remote-mobile-auto-archive-enabled-v1", "false");
      const project = document.getElementById("native-project");
      project.__reactFiber$fixture = { memoizedProps: { group: {
        projectKind: "remote", projectId: "fixture-project", hostId: __fixtureHost,
        hostDisplayName: "Remote " + "env" + "_" + "primary_fixture", cwd: "/fixture/design", label: "Design project",
      } }, memoizedState: null, return: null, updateQueue: null };
      globalThis.__fixtureRequests = [];
      globalThis.__fixtureUpdateStatus = { state: "current", version: "v1.5.32", message: null, canQueue: false, canCancel: false };
      globalThis.__CHATGPT_REMOTE_UPDATE__ = {
        getStatus: () => ({ ...__fixtureUpdateStatus }),
        request: async action => { __fixtureRequests.push(action); return { ...__fixtureUpdateStatus }; },
      };
      globalThis.__fixtureInventory = (name, cwd) => ({
        error: null, fetchedAt: Date.now(), generatedAt: Date.now(), hostDisplayName: name,
        pending: false, projects: [{ cwd, name: "Design project", rootPaths: [cwd] }], projectsAuthoritative: true,
        publisherVersion: 53, retryAt: 0, tasks: new Map(), threadScope: "user-visible", threadScopeGeneratedAt: Date.now(), threads: [], threadsAuthoritative: true,
      });
    });
    await page.evaluate(fixtureSource);
    await page.evaluate(() => {
      __crmpBrowserFixture.state.remoteProjectInventories.set(__fixtureHost, __fixtureInventory(null, "/fixture/design"));
      __crmpBrowserFixture.install();
    });
    const panel = page.locator("#codex-remote-mobile-project-panel");
    await panel.locator(".crmp-version").waitFor();
    assert.match(await panel.locator(".crmp-version").innerText(), /Remote Enabler · v1\.5\.35/u);
    assert.equal(await panel.locator(".crmp-version svg").count(), 1);
    assert.equal(await panel.locator(".crmp-settings").isVisible(), false, "version must be visible while Settings is closed");
    if (screenshotPath) await panel.locator(".crmp-update-panel").screenshot({ path: screenshotPath.replace(/\.png$/u, "-version.png") });
    await panel.locator(".crmp-version").click();
    assert.equal(await page.evaluate(() => __fixtureRequests.pop()), "check");
    // A missing sidecar must leave a visible version, icon, recovery instruction and release link.
    await page.evaluate(() => {
      globalThis.__savedFixtureUpdater = __CHATGPT_REMOTE_UPDATE__;
      delete globalThis.__CHATGPT_REMOTE_UPDATE__;
      __crmpBrowserFixture.state.updateStatus = null;
      __crmpBrowserFixture.render();
    });
    assert.match(await panel.locator(".crmp-update-panel").innerText(), /update service is not attached/u);
    assert.match(await panel.locator(".crmp-version").innerText(), /v1\.5\.35/u);
    assert.equal(await panel.locator(".crmp-version").isDisabled(), true);
    if (screenshotPath) await panel.locator(".crmp-update-panel").screenshot({ path: screenshotPath.replace(/\.png$/u, "-missing-updater.png") });
    assert.equal(await panel.getByRole("link", { name: "Release notes and downloads" }).count(), 1);
    await panel.getByRole("button", { name: "Native sidebar", exact: true }).click();
    assert.equal(await panel.locator(".crmp-version").isVisible(), true);
    await page.evaluate(() => { globalThis.__CHATGPT_REMOTE_UPDATE__ = __savedFixtureUpdater; __crmpBrowserFixture.state.updateStatus = null; __crmpBrowserFixture.render(); });
    await panel.getByRole("button", { name: "Device projects", exact: true }).click();
    const chips = panel.locator(".crmp-chip");
    await chips.filter({ hasText: "Remote device" }).waitFor();
    assert.doesNotMatch(await panel.innerText(), /primary_fixture|Remote env_/u);

    await page.evaluate(() => {
      __crmpBrowserFixture.state.remoteProjectInventories.set(__fixtureHost, __fixtureInventory("Peer desktop", "/fixture/design"));
      __crmpBrowserFixture.render();
    });
    await chips.filter({ hasText: "Peer desktop" }).waitFor();
    assert.equal(await page.evaluate(() => JSON.parse(localStorage.getItem("codex-remote-mobile-host-names-v1"))[__fixtureHost]), "Peer desktop");
    await page.evaluate(() => { __crmpBrowserFixture.state.hostDiscoveryDirty = true; __crmpBrowserFixture.render(); });
    assert.match(await chips.allTextContents().then(items => items.join("|")), /Peer desktop/u);

    await page.evaluate(() => {
      __fixtureUpdateStatus = { state: "available", version: "v1.5.33", message: "An update is available.", canQueue: true, canCancel: false };
      globalThis.dispatchEvent(new CustomEvent("chatgpt-remote-update-status", { detail: __fixtureUpdateStatus }));
    });
    const updateButton = panel.getByRole("button", { name: "Update available · v1.5.33", exact: true });
    await updateButton.waitFor();
    await updateButton.focus();
    await page.keyboard.press("Enter");
    assert.deepEqual(await page.evaluate(() => __fixtureRequests), ["queue"]);
    await panel.getByRole("button", { name: "Native sidebar", exact: true }).click();
    await updateButton.waitFor();
    await panel.getByRole("button", { name: "Device projects", exact: true }).click();

    await page.evaluate(() => {
      __fixtureUpdateStatus = { state: "queued", version: "v1.5.33", message: "Waiting for active tasks.", canQueue: false, canCancel: true };
      document.dispatchEvent(new CustomEvent("chatgpt-remote-update-status", { detail: __fixtureUpdateStatus }));
    });
    await panel.getByRole("button", { name: "Cancel", exact: true }).click();
    assert.deepEqual(await page.evaluate(() => __fixtureRequests), ["queue", "cancel"]);

    await page.evaluate(() => __CODEX_REMOTE_MOBILE_PROJECT_VIEW__.uninstall());
    await page.evaluate(fixtureSource);
    await page.evaluate(() => {
      __crmpBrowserFixture.state.remoteProjectInventories.set(__fixtureHost, __fixtureInventory(null, "/fixture/design"));
      __crmpBrowserFixture.state.remoteProjectInventories.set(__fixtureOlderHost, __fixtureInventory(null, "/fixture/older"));
      __crmpBrowserFixture.install();
    });
    await chips.filter({ hasText: "Peer desktop" }).waitFor();
    await chips.filter({ hasText: "Remote device" }).waitFor();
    assert.doesNotMatch(await panel.innerText(), /primary_fixture|older_fixture|Remote env_/u);
    const before = await page.evaluate(() => ({ ...__crmpBrowserFixture.state.counters }));
    await page.evaluate(() => { for (let index = 0; index < 200; index++) document.getElementById("outside").appendChild(document.createElement("span")); });
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const after = await page.evaluate(() => ({ ...__crmpBrowserFixture.state.counters }));
    assert.equal(after.renders, before.renders, "unrelated document mutations must not rerender the sidebar");
    assert.equal(after.hostDiscoveryScans, before.hostDiscoveryScans, "unrelated document mutations must not rescan host discovery");

    await page.evaluate(() => {
      __fixtureUpdateStatus = { state: "available", version: "v1.5.33", message: "An update is available.", canQueue: true, canCancel: false };
      globalThis.dispatchEvent(new CustomEvent("chatgpt-remote-update-status", { detail: __fixtureUpdateStatus }));
    });
    await updateButton.waitFor();
    // Settings stays reachable in both views, with no preference mutation.
    await panel.getByRole("button", { name: "Settings", exact: true }).click();
    await panel.getByRole("button", { name: "Auto-cleanup: off", exact: true }).waitFor();
    await panel.getByRole("button", { name: "Native sidebar", exact: true }).click();
    assert.match(await panel.innerText(), /permanently deletes/);
    await panel.getByRole("button", { name: "Device projects", exact: true }).click();
    assert.equal(await page.evaluate(() => localStorage.getItem("codex-remote-mobile-auto-archive-enabled-v1")), "false");
    await panel.getByRole("button", { name: "Settings", exact: true }).click();

    for (const state of ["checking", "available", "queued", "preparing", "closing", "updating", "restarting", "error", "unavailable", "current"]) {
      await page.evaluate(state => {
        __fixtureUpdateStatus = { state, version: "v1.5.33", canQueue: state === "available", canCancel: ["queued", "preparing"].includes(state), message: state === "queued" ? "Unknown activity" : "Fixture detail" };
        globalThis.dispatchEvent(new CustomEvent("chatgpt-remote-update-status", { detail: __fixtureUpdateStatus }));
      }, state);
      await page.waitForFunction(state => __crmpBrowserFixture.state.updateStatus.state === state, state);
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      assert.equal(await panel.locator(".crmp-update-panel").count(), 1);
      if (state === "queued") assert.match(await panel.innerText(), /Waiting for activity information/);
      if (state === "error") await panel.getByRole("button", { name: "Check again", exact: true }).waitFor();
      if (["queued", "preparing"].includes(state)) await panel.getByRole("button", { name: "Cancel", exact: true }).waitFor();
    }
    assert.equal(await page.locator('[role="status"][aria-live="polite"]').count(), 1);
    const liveStable = await page.evaluate(() => {
      const node = document.querySelector('[role="status"][aria-live="polite"]');
      const text = node.textContent;
      __crmpBrowserFixture.render(); __crmpBrowserFixture.render();
      return node === document.querySelector('[role="status"][aria-live="polite"]') && text === node.textContent;
    });
    assert.ok(liveStable, "status region must survive background rerenders");
    await panel.getByRole("button", { name: "Settings", exact: true }).focus();
    await page.evaluate(() => __crmpBrowserFixture.render());
    assert.equal(await page.evaluate(() => document.activeElement.textContent), "Settings");
    const emptyStates = await page.evaluate(() => {
      const f = __crmpBrowserFixture, id = "ux-fixture";
      f.state.displayedHosts.push({ id, name: "UX device", availabilityKnown: true, available: false });
      const offline = f.emptyInventoryMessage(id);
      f.state.displayedHosts.at(-1).available = true;
      const loading = f.emptyInventoryMessage(id);
      f.state.remoteProjectInventories.set(id, __fixtureInventory("UX device", "/ux"));
      const empty = f.emptyInventoryMessage(id);
      const filtered = f.emptyInventoryMessage(id, true);
      f.state.remoteProjectInventories.get(id).generatedAt = Date.now() - 200000;
      const stale = f.emptyInventoryMessage(id);
      f.state.remoteProjectInventories.delete(id);
      return { offline, loading, empty, filtered, stale };
    });
    assert.match(emptyStates.offline, /disconnected/);
    assert.match(emptyStates.loading, /Loading/);
    assert.match(emptyStates.empty, /No tasks in this project/);
    assert.match(emptyStates.filtered, /Choose All/);
    assert.match(emptyStates.stale, /out of date/);

    // Exercise aliases through actual controls, preserving both caret and verified identity.
    await panel.locator(".crmp-devices > summary").click();
    let aliasInput = panel.getByRole("textbox", { name: "Local alias for Peer desktop", exact: true });
    await aliasInput.fill("My local alias");
    await aliasInput.press("Home");
    await aliasInput.press("ArrowRight");
    await page.evaluate(() => __crmpBrowserFixture.render());
    aliasInput = panel.getByRole("textbox", { name: "Local alias for Peer desktop", exact: true });
    assert.equal(await aliasInput.inputValue(), "My local alias");
    assert.equal(await aliasInput.evaluate(element => element.selectionStart), 1);
    await aliasInput.press("Enter");
    await chips.filter({ hasText: "My local alias" }).waitFor();
    assert.equal(await page.evaluate(() => JSON.parse(localStorage.getItem("codex-remote-mobile-host-names-v1"))[__fixtureHost]), "Peer desktop");
    await page.evaluate(() => __CODEX_REMOTE_MOBILE_PROJECT_VIEW__.uninstall());
    await page.evaluate(fixtureSource);
    await page.evaluate(() => {
      __crmpBrowserFixture.state.remoteProjectInventories.set(__fixtureHost, __fixtureInventory(null, "/fixture/design"));
      __crmpBrowserFixture.state.remoteProjectInventories.set(__fixtureOlderHost, __fixtureInventory(null, "/fixture/older"));
      __crmpBrowserFixture.install();
    });
    await chips.filter({ hasText: "My local alias" }).waitFor();
    await panel.locator(".crmp-devices > summary").click();
    await panel.locator(".crmp-device-card").filter({ hasText: "My local alias" }).getByRole("button", {name:"Reset alias", exact:true}).click();
    await chips.filter({ hasText: "Peer desktop" }).waitFor();
    const refreshed = await page.evaluate(() => {
      const a = __crmpBrowserFixture.refreshDeviceHealth();
      const b = __crmpBrowserFixture.refreshDeviceHealth();
      return [a, b];
    });
    assert.deepEqual(refreshed, [true, false], "health refresh must coalesce repeated clicks");
    await panel.getByRole("button", { name: "Settings", exact: true }).click();
    await panel.locator(".crmp-feature > summary").filter({ hasText: "Cleanup preview and history" }).click();
    await panel.getByRole("button", { name: "Refresh cleanup preview", exact: true }).click();
    await panel.getByText(/Preview is unavailable/).waitFor();
    assert.equal(await page.evaluate(() => localStorage.getItem("codex-remote-mobile-auto-archive-enabled-v1")), "false");
    await page.evaluate(() => {
      __fixtureUpdateStatus = { state:"current", version:"v1.5.34", details: {
        installedVersion:"v1.5.34", availableVersion:null, lastCheckedAt:Date.now(), historyAvailable:true,
        history:[{state:"restart-confirmed",version:"v1.5.34",at:Date.now()}]
      } };
      __crmpBrowserFixture.state.featureOpen.updates = true;
      __crmpBrowserFixture.state.featureOpen.diagnostics = true;
      globalThis.dispatchEvent(new CustomEvent("chatgpt-remote-update-status", { detail: __fixtureUpdateStatus }));
      Object.defineProperty(navigator, "clipboard", { configurable:true, value:{writeText:async text => { globalThis.__copiedDiagnostic = text; }} });
    });
    await panel.getByText(/Relaunch confirmed/).waitFor();
    assert.equal(await panel.getByRole("link", {name:"Installed release notes: v1.5.34", exact:true}).getAttribute("href"), "https://github.com/Belgian-Coder/ChatGPT-Remote-Enabler/releases/tag/v1.5.34");
    await panel.getByRole("button", { name: "Generate diagnostic preview", exact: true }).click();
    const json = await panel.getByRole("textbox", {name:"Diagnostic JSON preview", exact:true}).inputValue();
    assert.doesNotMatch(json, /Peer desktop|My local alias|primary_fixture|older_fixture|Design project|\/fixture\//);
    await panel.getByRole("button", { name: "Copy preview", exact: true }).click();
    await page.waitForFunction(() => typeof globalThis.__copiedDiagnostic === "string");
    assert.equal(await page.evaluate(() => __copiedDiagnostic), json);
    const downloadEvent = page.waitForEvent("download");
    await panel.getByRole("button", { name: "Save JSON", exact: true }).click();
    const download = await downloadEvent;
    assert.equal(fs.readFileSync(await download.path(), "utf8"), json, "download must exactly match the visible preview");
    await page.evaluate(() => {
      __crmpBrowserFixture.state.featureOpen = {};
      __crmpBrowserFixture.state.cleanupPreviewError = null;
      __crmpBrowserFixture.render();
    });

    await page.evaluate(() => {
      __crmpBrowserFixture.state.featureOpen.connection = true;
      __crmpBrowserFixture.state.transferStats.set(__fixtureHost, { reads: 3, writes: 2, receivedBase64Bytes: 1200, sentBase64Bytes: 600, failures: 1, lastReadMs: 40, lastWriteMs: 35 });
      __crmpBrowserFixture.state.healthRefreshUntil = 0;
      __crmpBrowserFixture.render();
    });
    const troubleshooting = panel.locator("details.crmp-feature").filter({ has: page.locator("summary", { hasText: "Connection troubleshooting" }) });
    assert.match(await troubleshooting.innerText(), /Next step:/u);
    assert.match(await troubleshooting.innerText(), /3 inventory reads, 2 cache write attempts/u);
    await troubleshooting.getByRole("button", { name: "Refresh connection evidence", exact: true }).click();
    await page.waitForFunction(() => [...document.querySelectorAll("button")].some(button => button.textContent === "Refresh connection evidence" && button.disabled));
    assert.equal(await troubleshooting.getByRole("button", { name: "Refresh connection evidence", exact: true }).isDisabled(), true);
    assert.match(await troubleshooting.innerText(), /Pending reads are reused/u);
    const connectionDiagnostics = await page.evaluate(() => __crmpBrowserFixture.diagnosticSnapshot(__crmpBrowserFixture.collectModel()));
    assert.ok(connectionDiagnostics.devices.some(device => device.transfer?.sentBase64Bytes === 600));
    assert.doesNotMatch(JSON.stringify(connectionDiagnostics), /primary_fixture|Peer desktop/u);

    for (const theme of ["dark", "light"]) {
      await page.evaluate(theme => {
        document.documentElement.style.colorScheme = theme;
        const dark = theme === "dark";
        document.documentElement.style.setProperty("--color-text", dark ? "#eeeeee" : "#202020");
        document.documentElement.style.setProperty("--color-text-secondary", dark ? "#cccccc" : "#444444");
        document.documentElement.style.setProperty("--color-background-inverted", dark ? "#333333" : "#dedede");
        document.body.style.color = dark ? "#eeeeee" : "#202020";
        document.querySelector("nav").style.background = dark ? "#1b222f" : "#ffffff";
        __fixtureUpdateStatus = { state: "queued", version: "v1.5.33", canCancel: true, message: "Waiting for active tasks" };
        __crmpBrowserFixture.state.settingsOpen = true;
        __crmpBrowserFixture.state.deviceDetailsOpen = true;
        __crmpBrowserFixture.state.featureOpen.connection = true;
        __crmpBrowserFixture.state.remoteProjectInventories.get(__fixtureHost).hostDisplayName = "Peer desktop with a very long device name";
        globalThis.dispatchEvent(new CustomEvent("chatgpt-remote-update-status", { detail: __fixtureUpdateStatus }));
      }, theme);
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      for (const width of [280, 320, 400]) {
        for (const zoom of [1, 2]) {
          await page.locator("nav").evaluate((element, values) => { element.style.width = `${values.width}px`; element.style.zoom = values.zoom; }, {width, zoom});
          const controls = await panel.locator("button").evaluateAll(elements => elements.filter(element => element.getBoundingClientRect().width > 0).map(element => ({ text: element.textContent, client: element.clientWidth, scroll: element.scrollWidth, height: element.getBoundingClientRect().height, left: element.getBoundingClientRect().left, right: element.getBoundingClientRect().right, project: element.classList.contains("crmp-project-toggle") })));
          for (const control of controls) {
            if (!control.project) assert.ok(control.scroll <= control.client + 1, `Button text clipped at ${width}px: ${control.text}`);
            assert.ok(control.left >= 0 && control.right <= width * zoom, `Button exceeds sidebar at ${width}px: ${control.text}`);
            assert.ok(control.height / zoom >= 24, `Undersized control: ${control.text}`);
          }
        }
      }
      await page.locator("nav").evaluate(element => { element.style.width = "320px"; element.style.zoom = 1; });
      const colors = await panel.locator(".crmp-help,.crmp-mode,.crmp-chip").evaluateAll(elements => elements.filter(el => el.getBoundingClientRect().height).map(el => ({ text: el.textContent, color: getComputedStyle(el).color })));
      const luminance = rgb => rgb.map(value => { value /= 255; return value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4; }).reduce((sum, value, index) => sum + value * [.2126,.7152,.0722][index], 0);
      const background = luminance(theme === "dark" ? [27,34,47] : [255,255,255]);
      for (const item of colors) {
        const foreground = luminance(item.color.match(/[\d.]+/g).slice(0,3).map(Number));
        const contrast = (Math.max(foreground, background) + .05) / (Math.min(foreground, background) + .05);
        assert.ok(contrast >= 4.5, `Low fixture text contrast (${contrast}): ${item.text}`);
      }
      if (screenshotPath) await panel.screenshot({ path: screenshotPath.replace(/\.png$/u, `-${theme}.png`) });
      if (screenshotPath) await troubleshooting.screenshot({ path: screenshotPath.replace(/\.png$/u, `-connection-${theme}.png`) });
    }
    if (screenshotPath) {
      await page.evaluate(() => {
        __crmpBrowserFixture.state.settingsOpen = true;
        __crmpBrowserFixture.state.deviceDetailsOpen = false;
        __crmpBrowserFixture.state.featureOpen = { cleanup: true, updates: true, diagnostics: true };
        __fixtureUpdateStatus = { state: "current", version: "v1.5.35", details: { installedVersion: "v1.5.35", lastCheckedAt: Date.now(), historyAvailable: true, history: [{ at: Date.now(), state: "checked", version: "v1.5.35" }] } };
        globalThis.dispatchEvent(new CustomEvent("chatgpt-remote-update-status", { detail: __fixtureUpdateStatus }));
      });
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      await panel.screenshot({ path: screenshotPath.replace(/\.png$/u, "-features.png") });
    }
    await page.emulateMedia({ reducedMotion: "reduce" });
    assert.ok(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches));
    await page.evaluate(() => {
      __crmpBrowserFixture.state.settingsOpen = false;
      __crmpBrowserFixture.state.deviceDetailsOpen = false;
      __fixtureUpdateStatus = { state: "current", version: "v1.5.35", canQueue: false };
      globalThis.dispatchEvent(new CustomEvent("chatgpt-remote-update-status", { detail: __fixtureUpdateStatus }));
    });
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    if (screenshotPath) await panel.screenshot({ path: screenshotPath });
    assert.deepEqual(errors, [], "the real renderer must not raise browser errors");
    console.log(JSON.stringify({ alwaysVisibleVersionAndIcon: true, missingUpdaterRecoveryBothViews: true, guidedConnectionTroubleshooting: true, transferDiagnosticsAllowlisted: true, featureControls: true, aliasReload: true, caretPreserved: true, healthRefreshCoalesced: true, diagnosticCopyAndDownload: true, uxStates: 10, themes: 2, sidebarWidths: [280,320,400], scaling: [1,2], fixtureTextContrast: true, stableAnnouncements: true, focusRestored: true, realChromium: true, realModelAndRender: true, neutralName: true, metadataArrival: true, reinjection: true, updateEventBothTargets: true, keyboardQueue: true, nativeViewUpdate: true, cancel: true, unrelatedMutations: 200, extraRenders: after.renders - before.renders, extraHostScans: after.hostDiscoveryScans - before.hostDiscoveryScans }));
  } finally { await browser.close(); }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
