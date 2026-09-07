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
const fixtureSource = source.replace("  return install();\n})();", "  globalThis.__crmpBrowserFixture = { state, install, render, collectModel, emptyInventoryMessage, refreshDeviceHealth, requestDeviceRefresh, diagnosticSnapshot, discoverHostNames, discoverRemoteRuntimes, hydrateNativeInventory, invalidateDiscoveryCaches, openNativeTask, schedule, scheduleNativeInventoryHydration, scheduleRemoteProjectInventory, startNativeProjectThread, uninstall };\n})();");
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
      globalThis.__CODEX_REMOTE_MOBILE_CONFIG__ = { localDisplayName: "Local device", helperVersion: "v1.5.49", hostDisplayNames: {} };
      localStorage.setItem("codex-remote-mobile-auto-register-enabled-v1", "false");
      localStorage.setItem("codex-remote-mobile-auto-archive-enabled-v1", "false");
      const project = document.getElementById("native-project");
      project.setAttribute("data-app-action-sidebar-project-list-id", "fixture-project");
      const projectNew = document.createElement("button");
      projectNew.setAttribute("aria-label", "Start new chat in Design project");
      projectNew.textContent = "New chat";
      project.appendChild(projectNew);
      globalThis.__fixtureProject = project;
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
      globalThis.__setFixtureRuntime = runtime => {
        globalThis.__fixtureProject.__reactFiber$fixture.memoizedState = runtime ? [{ hostId: __fixtureHost, requestClient: runtime.requestClient, fetchFromHost: runtime.fetchFromHost }] : null;
        if (globalThis.__crmpBrowserFixture?.state) {
          globalThis.__crmpBrowserFixture.state.remoteRuntimeCache.clear();
          globalThis.__crmpBrowserFixture.state.remoteRuntimeScannedAt = 0;
        }
      };
    });
    await page.evaluate(fixtureSource);
    await page.evaluate(() => {
      __crmpBrowserFixture.state.remoteProjectInventories.set(__fixtureHost, __fixtureInventory(null, "/fixture/design"));
      __crmpBrowserFixture.install();
    });
    const panel = page.locator("#codex-remote-mobile-project-panel");
    const settingsButton = panel.getByRole("button", { name: "Settings", exact: true });
    const setSettingsOpen = async open => { if (await settingsButton.getAttribute("aria-expanded") !== String(open)) await settingsButton.click(); };
    const refreshControl = panel.locator(".crmp-force-refresh");
    assert.equal(await refreshControl.locator(".crmp-refresh-icon").count(), 1, "Force refresh must use one compact icon");
    assert.equal(await refreshControl.textContent(), "", "Force refresh icon must remain compact and label itself accessibly");
    const refreshGeometry = await page.evaluate(() => {
      const settings = document.querySelector("#codex-remote-mobile-project-panel .crmp-mode[aria-controls]");
      const refresh = document.querySelector("#codex-remote-mobile-project-panel .crmp-force-refresh");
      const settingsRect = settings.getBoundingClientRect();
      const refreshRect = refresh.getBoundingClientRect();
      return { gap: refreshRect.left - settingsRect.right, inlineMargin: getComputedStyle(refresh).marginInlineStart };
    });
    assert.ok(refreshGeometry.gap >= -1 && refreshGeometry.gap <= 12, "Force refresh must sit immediately to the right of Settings");
    assert.equal(refreshGeometry.inlineMargin, "0px", "Force refresh must not push itself to the far edge of the control row");
    await page.evaluate(() => {
      const state = __crmpBrowserFixture.state;
      state.deviceRefreshPending = true;
      state.deviceRefreshQueued = false;
      __crmpBrowserFixture.render();
    });
    assert.equal(await refreshControl.getAttribute("aria-busy"), "true", "Force refresh must expose its pending state");
    assert.equal(await refreshControl.locator(".crmp-refresh-icon").getAttribute("class").then(value => value.includes("crmp-status-spin")), true, "Force refresh must spin while a refresh is pending");
    await page.evaluate(() => { __crmpBrowserFixture.state.deviceRefreshPending = false; __crmpBrowserFixture.render(); });
    // The replacement must leave the native global navigation and explicit
    // project New chat action usable. Background discovery with the legacy
    // preference enabled must never open the native Add project dialog.
    await page.evaluate(() => {
      globalThis.__fixtureNativeGlobalNewChats = 0;
      document.querySelector("nav > button.global").addEventListener("click", () => { globalThis.__fixtureNativeGlobalNewChats += 1; });
      globalThis.__fixtureNativeProjectNewChats = 0;
      document.querySelector("#native-project button[aria-label^=\"Start new chat in \"]").addEventListener("click", () => { globalThis.__fixtureNativeProjectNewChats += 1; });
      localStorage.setItem("codex-remote-mobile-auto-register-enabled-v1", "true");
      __crmpBrowserFixture.state.localRegisteredProjectsFetchedAt = Date.now();
      __crmpBrowserFixture.render();
    });
    await page.locator("nav > button.global").first().click();
    await panel.getByRole("button", { name: "Start new chat in Design project", exact: true }).click({ force: true });
    assert.equal(await page.evaluate(() => __fixtureNativeGlobalNewChats), 1, "global New chat must remain connected outside the replacement panel");
    assert.equal(await page.evaluate(() => __fixtureNativeProjectNewChats), 1, "explicit project New chat must invoke the native action");
    assert.equal(await page.locator('[role="dialog"],.codex-dialog').count(), 0, "explicit New chat must not open a remote-project registration dialog");
    await page.evaluate(() => { localStorage.setItem("codex-remote-mobile-auto-register-enabled-v1", "false"); __crmpBrowserFixture.render(); });

    // Install a runtime through the mounted React fiber and force a refresh
    // through the browser-visible control. The selected filter must survive,
    // retry gates must be bypassed, and a refresh must remain dialog-free.
    await page.evaluate(() => {
      const hostId = __fixtureHost;
      const cwd = "/fixture/design";
      const threadId = "browser-refresh-thread";
      const payload = { generatedAt: new Date().toISOString(), hostDisplayName: "Peer desktop", projects: [{ cwd, name: "Design project", rootPaths: [cwd] }], publisherVersion: 53, schemaVersion: 1, tasks: [], threadScope: "user-visible", threadScopeGeneratedAt: new Date().toISOString(), threads: [{ cwd, id: threadId, projectId: "fixture-project", status: "idle", title: "Fresh browser response" }] };
      const encode = text => btoa(String.fromCharCode(...new TextEncoder().encode(text)));
      globalThis.__fixtureDiscoveryCalls = [];
      const runtime = { requestClient: { sendRequest: async (method, params) => {
        __fixtureDiscoveryCalls.push({ method, params });
        if (method === "thread/list") return { data: [{ cwd, id: threadId, projectId: "fixture-project", status: "idle", title: "Fresh browser response" }], nextCursor: null };
        if (method === "config/read") return { codexHome: "C:\\Fixture\\browser-refresh\\.codex" };
        if (method === "fs/readFile") return { dataBase64: encode(JSON.stringify(payload)) };
        throw new Error(`Unexpected fixture request: ${method}`);
      } } };
      __setFixtureRuntime(runtime);
      __crmpBrowserFixture.state.threadInventories.set(hostId, { error: null, fetchedAt: Date.now() - 1000, hostId, pages: 1, retryAt: Date.now() + 60000, threads: [{ cwd, id: "browser-old-thread", status: "idle", title: "Old browser response" }], truncated: false });
      __crmpBrowserFixture.state.filter = hostId;
      if (__crmpBrowserFixture.state.inventoryHydrationTimer !== null) clearTimeout(__crmpBrowserFixture.state.inventoryHydrationTimer);
      __crmpBrowserFixture.state.inventoryHydrationTimer = null;
      __crmpBrowserFixture.state.inventoryHydrationStarted = true;
      __crmpBrowserFixture.state.inventoryHydrationDirty = false;
    });
    await page.evaluate(() => {
      const composer = document.createElement("textarea");
      composer.id = "refresh-draft";
      composer.value = "Keep this unsent draft";
      document.body.appendChild(composer);
      history.replaceState(null, "", "#open-chat-preserved");
      const nav = document.querySelector("nav");
      nav.style.cssText += ";height:200px;min-height:0;overflow:auto";
      nav.scrollTop = 35;
      __crmpBrowserFixture.state.collapsed.add("refresh-collapsed-fixture");
      composer.focus({ preventScroll: true });
      composer.setSelectionRange(5, 9);
      globalThis.__refreshPreservation = { scroll: nav.scrollTop, route: location.href, collapsed: [...__crmpBrowserFixture.state.collapsed] };
      document.querySelector(".crmp-force-refresh").click();
    });
    await page.waitForFunction(() => !__crmpBrowserFixture.state.deviceRefreshPending);
    const browserRefresh = await page.evaluate(() => ({
      calls: __fixtureDiscoveryCalls.filter(call => call.method === "thread/list").length,
      filter: __crmpBrowserFixture.state.filter,
      dialogs: document.querySelectorAll('[role="dialog"],.codex-dialog').length,
      thread: __crmpBrowserFixture.state.threadInventories.get(__fixtureHost)?.threads?.[0]?.id,
    }));
    assert.deepEqual(browserRefresh, { calls: 1, filter: await page.evaluate(() => __fixtureHost), dialogs: 0, thread: "browser-refresh-thread" }, "Force refresh must preserve the selected device, read fresh membership once, and stay dialog-free");
    const preservedRefresh = await page.evaluate(() => ({
      draft: document.getElementById("refresh-draft").value,
      selection: [document.getElementById("refresh-draft").selectionStart, document.getElementById("refresh-draft").selectionEnd],
      focus: document.activeElement.id,
      scroll: document.querySelector("nav").scrollTop === __refreshPreservation.scroll,
      route: location.href === __refreshPreservation.route,
      collapsed: JSON.stringify([...__crmpBrowserFixture.state.collapsed]) === JSON.stringify(__refreshPreservation.collapsed),
    }));
    assert.deepEqual(preservedRefresh, { draft: "Keep this unsent draft", selection: [5, 9], focus: "refresh-draft", scroll: true, route: true, collapsed: true }, "refresh must preserve the open route, composer, caret, focus, scroll and expanded state");
    await page.evaluate(() => {
      globalThis.__fixtureNavigationCalls = [];
      __crmpBrowserFixture.state.navigationBridge = {
        navigate: () => {},
        navigateToLocalConversation: (conversationId, hostId) => { __fixtureNavigationCalls.push({ conversationId, hostId }); },
      };
      __crmpBrowserFixture.render();
    });
    const freshTask = panel.getByRole("button", { name: /Fresh browser response/u, exact: true });
    await freshTask.waitFor();
    await freshTask.click();
    const fixtureHost = await page.evaluate(() => __fixtureHost);
    assert.deepEqual(await page.evaluate(() => __fixtureNavigationCalls), [{ conversationId: "browser-refresh-thread", hostId: fixtureHost }], "A direct remote task must navigate to its conversation on the owning host");
    await page.evaluate(() => { document.getElementById("refresh-draft").remove(); document.querySelector("nav").removeAttribute("style"); __crmpBrowserFixture.state.collapsed.delete("refresh-collapsed-fixture"); });
    await page.evaluate(() => {
      __setFixtureRuntime(null);
      __crmpBrowserFixture.state.filter = "all";
      __crmpBrowserFixture.state.threadInventories.delete(__fixtureHost);
      __crmpBrowserFixture.state.remoteProjectInventories.set(__fixtureHost, __fixtureInventory(null, "/fixture/design"));
      localStorage.removeItem("codex-remote-mobile-host-names-v1");
      localStorage.removeItem("codex-remote-mobile-native-host-names-v1");
      __crmpBrowserFixture.state.hostDiscoveryDirty = true;
      __crmpBrowserFixture.render();
    });
    assert.equal(await panel.locator(".crmp-settings").isVisible(), false);
    assert.equal(await panel.locator(".crmp-version").isVisible(), false, "update details must stay behind Settings");
    assert.equal(await panel.locator(".crmp-devices").isVisible(), false, "device health must stay behind Settings");
    assert.equal(await panel.locator(":scope > .crmp-update-panel,:scope > .crmp-devices").count(), 0);
    await setSettingsOpen(true);
    assert.equal(await page.evaluate(() => __crmpBrowserFixture.state.settingsOpen), true, "Settings must remain open after Force refresh");
    await panel.locator(".crmp-version").waitFor();
    assert.match(await panel.locator(".crmp-version").innerText(), /Remote Enabler · v1\.5\.49/u);
    assert.equal(await panel.locator(".crmp-version svg").count(), 1);
    assert.equal(await panel.locator(".crmp-settings").isVisible(), true, "version is available inside Settings");
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
    assert.match(await panel.locator(".crmp-version").innerText(), /v1\.5\.49/u);
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
    await setSettingsOpen(true);
    await updateButton.waitFor();
    await updateButton.focus();
    await page.keyboard.press("Enter");
    assert.deepEqual(await page.evaluate(() => __fixtureRequests), ["queue"]);
    await panel.getByRole("button", { name: "Native sidebar", exact: true }).click();
    await setSettingsOpen(true);
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
    assert.deepEqual(await chips.allTextContents(), ["All", "This device", "Peer desktop", "Remote device"], "device filters must keep the current device second and sort remote display names");
    assert.doesNotMatch(await panel.innerText(), /primary_fixture|older_fixture|Remote env_/u);
    await setSettingsOpen(false);
    const stableRender = await page.evaluate(() => {
      const fixture = __crmpBrowserFixture;
      const panelElement = document.getElementById("codex-remote-mobile-project-panel");
      const firstChild = panelElement.firstElementChild;
      const before = { ...fixture.state.counters };
      fixture.state.transferStats.set(__fixtureHost, { reads: 11, writes: 7, receivedBase64Bytes: 1200, sentBase64Bytes: 600, failures: 1, lastReadMs: 40, lastWriteMs: 35 });
      fixture.render();
      return {
        sameFirstChild: firstChild === panelElement.firstElementChild,
        replacements: fixture.state.counters.panelReplacements - before.panelReplacements,
        skips: fixture.state.counters.panelRenderSkips - before.panelRenderSkips,
      };
    });
    assert.deepEqual(stableRender, { sameFirstChild: true, replacements: 0, skips: 1 }, "hidden diagnostic changes must not replace an otherwise identical closed sidebar");
    await setSettingsOpen(true);
    assert.match(await panel.locator(".crmp-settings").textContent(), /11 inventory reads/u, "opening Settings must build the latest hidden diagnostic data");
    await setSettingsOpen(false);
    const nativeActionRefresh = await page.evaluate(() => {
      const fixture = __crmpBrowserFixture;
      const panelElement = document.getElementById("codex-remote-mobile-project-panel");
      const firstChild = panelElement.firstElementChild;
      const oldToggle = document.querySelector("#native-project [data-app-action-sidebar-project-collapsed]");
      let oldClicks = 0;
      let currentClicks = 0;
      oldToggle.addEventListener("click", () => { oldClicks += 1; });
      const currentToggle = oldToggle.cloneNode(true);
      currentToggle.addEventListener("click", () => { currentClicks += 1; });
      oldToggle.replaceWith(currentToggle);
      fixture.render();
      panelElement.querySelector(".crmp-project-toggle").click();
      return { replaced: firstChild !== panelElement.firstElementChild, oldClicks, currentClicks };
    });
    assert.deepEqual(nativeActionRefresh, { replaced: true, oldClicks: 0, currentClicks: 1 }, "a same-markup native control replacement must refresh the custom action closure");
    // Replacing and clicking the native toggle intentionally schedules a renderer
    // pass. Drain it before taking the unrelated-mutation counter baseline.
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
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
    await setSettingsOpen(true);
    await updateButton.waitFor();
    // Settings stays reachable in both views, with no preference mutation.
    await setSettingsOpen(true);
    await panel.locator(".crmp-feature > summary").filter({ hasText: /^Automatic cleanup$/u }).click();
    await panel.getByRole("button", { name: "Auto-cleanup: off", exact: true }).waitFor();
    await panel.getByRole("button", { name: "Native sidebar", exact: true }).click();
    assert.match(await panel.innerText(), /permanently deletes/);
    await panel.getByRole("button", { name: "Device projects", exact: true }).click();
    assert.equal(await page.evaluate(() => localStorage.getItem("codex-remote-mobile-auto-archive-enabled-v1")), "false");
    await setSettingsOpen(true);

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
    assert.equal(emptyStates.empty, "No chats");
    assert.match(emptyStates.filtered, /Choose All/);
    assert.match(emptyStates.stale, /out of date/);

    // Exercise shared aliases through the actual Device health controls while
    // preserving both caret position and the separate verified identity.
    await setSettingsOpen(true);
    await panel.locator(".crmp-devices > summary").click();
    assert.ok(await panel.getByText("Saved aliases sync automatically with updated connected devices. Offline devices catch up when they reconnect.", { exact: true }).count() >= 1);
    let aliasInput = panel.getByRole("textbox", { name: "Shared alias for Peer desktop", exact: true });
    await aliasInput.fill("My shared alias");
    await aliasInput.press("Home");
    await aliasInput.press("ArrowRight");
    await page.evaluate(() => __crmpBrowserFixture.render());
    aliasInput = panel.getByRole("textbox", { name: "Shared alias for Peer desktop", exact: true });
    assert.equal(await aliasInput.inputValue(), "My shared alias");
    assert.equal(await aliasInput.evaluate(element => element.selectionStart), 1);
    await aliasInput.press("Enter");
    await chips.filter({ hasText: "My shared alias" }).waitFor();
    await panel.getByText("Alias saved. Sharing is queued and retries when devices reconnect.", { exact: true }).waitFor();
    const savedAliasRecord = await page.evaluate(() => JSON.parse(localStorage.getItem("codex-remote-mobile-device-alias-records-v2"))[__fixtureHost]);
    assert.equal(savedAliasRecord.schemaVersion, 1);
    assert.equal(savedAliasRecord.value, "My shared alias");
    assert.ok(Number.isFinite(savedAliasRecord.updatedAt) && savedAliasRecord.updatedAt > 0);
    assert.equal(typeof savedAliasRecord.writerId, "string");
    assert.equal(await page.evaluate(() => JSON.parse(localStorage.getItem("codex-remote-mobile-host-names-v1"))[__fixtureHost]), "Peer desktop");
    assert.deepEqual(await chips.allTextContents(), ["All", "This device", "My shared alias", "Remote device"], "a shared alias must participate in friendly-name filter ordering without moving the current device");
    if (screenshotPath) {
      await panel.locator(".crmp-device-card").filter({ hasText: "Reported name: Peer desktop" }).screenshot({ path: screenshotPath.replace(/\.png$/u, "-shared-alias.png") });
    }
    await page.evaluate(() => __CODEX_REMOTE_MOBILE_PROJECT_VIEW__.uninstall());
    await page.evaluate(fixtureSource);
    await page.evaluate(() => {
      __crmpBrowserFixture.state.remoteProjectInventories.set(__fixtureHost, __fixtureInventory(null, "/fixture/design"));
      __crmpBrowserFixture.state.remoteProjectInventories.set(__fixtureOlderHost, __fixtureInventory(null, "/fixture/older"));
      __crmpBrowserFixture.install();
    });
    await chips.filter({ hasText: "My shared alias" }).waitFor();
    assert.deepEqual(await chips.allTextContents(), ["All", "This device", "My shared alias", "Remote device"], "the shared alias and filter order must survive a full renderer reinstall");
    await setSettingsOpen(true);
    await panel.locator(".crmp-devices > summary").click();
    aliasInput = panel.getByRole("textbox", { name: "Shared alias for Peer desktop", exact: true });
    assert.equal(await aliasInput.inputValue(), "My shared alias");
    await panel.locator(".crmp-device-card").filter({ hasText: "My shared alias" }).getByRole("button", {name:"Reset alias", exact:true}).click();
    await chips.filter({ hasText: "Peer desktop" }).waitFor();
    await panel.getByText("Alias reset. Sharing is queued and retries when devices reconnect.", { exact: true }).waitFor();
    const resetAliasRecord = await page.evaluate(() => JSON.parse(localStorage.getItem("codex-remote-mobile-device-alias-records-v2"))[__fixtureHost]);
    assert.equal(resetAliasRecord.schemaVersion, 1);
    assert.equal(resetAliasRecord.value, null, "reset must retain a shareable tombstone rather than deleting the v2 record");
    assert.ok(resetAliasRecord.updatedAt > savedAliasRecord.updatedAt);
    assert.deepEqual(await chips.allTextContents(), ["All", "This device", "Peer desktop", "Remote device"], "reset must restore verified-name ordering while keeping the current device second");
    const refreshed = await page.evaluate(() => {
      const a = __crmpBrowserFixture.refreshDeviceHealth();
      const b = __crmpBrowserFixture.refreshDeviceHealth();
      return [a, b];
    });
    assert.deepEqual(refreshed, [true, false], "health refresh must coalesce repeated clicks");
    await setSettingsOpen(true);
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
    assert.doesNotMatch(json, /Peer desktop|My shared alias|primary_fixture|older_fixture|Design project|\/fixture\//);
    await panel.getByRole("button", { name: "Copy preview", exact: true }).click();
    await page.waitForFunction(() => typeof globalThis.__copiedDiagnostic === "string");
    assert.equal(await page.evaluate(() => __copiedDiagnostic), json);
    await page.evaluate(() => {
      globalThis.electronBridge = { sendMessageFromView: async () => {} };
      __crmpBrowserFixture.state.localFetchFromHost = async (action, options) => {
        if (action !== "save-file") return { value: [] };
        globalThis.__savedDiagnostic = options.params;
        return { path: "/chosen/diagnostics.json" };
      };
    });
    await panel.getByRole("button", { name: "Save JSON", exact: true }).click();
    await panel.getByText("JSON saved to /chosen/diagnostics.json", {exact:true}).waitFor();
    const saved = await page.evaluate(() => __savedDiagnostic);
    assert.equal(saved.kind, "contents");
    assert.equal(saved.suggestedFilename, "remote-enabler-diagnostics.json");
    assert.equal(Buffer.from(saved.contentsBase64, "base64").toString("utf8"), json, "native save must exactly match the displayed preview");
    await page.evaluate(() => { __crmpBrowserFixture.state.localFetchFromHost = async () => ({ path: null }); });
    await panel.getByRole("button", { name: "Save JSON", exact: true }).click();
    await panel.getByText("Save cancelled. No file was saved.", {exact:true}).waitFor();
    await page.evaluate(() => { __crmpBrowserFixture.state.localFetchFromHost = async () => { throw Error("fixture save failed"); }; });
    await panel.getByRole("button", { name: "Save JSON", exact: true }).click();
    await panel.getByText(/JSON could not be saved/).waitFor();
    await page.evaluate(() => { delete globalThis.electronBridge; __crmpBrowserFixture.state.localFetchFromHost = null; });
    await page.evaluate(() => {
      __crmpBrowserFixture.state.featureOpen = {};
      __crmpBrowserFixture.state.cleanupPreviewError = null;
      __crmpBrowserFixture.state.diagnosticFeedback = null;
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
      const colors = await panel.locator(".crmp-help,.crmp-mode,.crmp-chip,.crmp-sync-status").evaluateAll(elements => elements.filter(el => el.getBoundingClientRect().height).map(el => ({ text: el.textContent, color: getComputedStyle(el).color })));
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
      // Documentation captures use representative synthetic data after the
      // edge-case assertions. Only the isolated fixture inventory is changed.
      await page.evaluate(() => {
        const state = __crmpBrowserFixture.state;
        state.collapsed.clear();
        state.filter = "all";
        state.inventoryHydrationError = null;
        state.threadInventories.set("local", { fetchedAt: Date.now(), threads: [], error: null, truncated: false });
        const desktop = __fixtureInventory("Studio desktop", "/fixture/design");
        desktop.helperVersion = "v1.5.49";
        desktop.threads = [
          { id: "demo-layout", cwd: "/fixture/design", title: "Refine the dashboard layout", status: "loading", hasUnreadTurn: false },
          { id: "demo-tests", cwd: "/fixture/design", title: "Review the accessibility checks", status: "idle", hasUnreadTurn: true },
        ];
        const laptop = __fixtureInventory("Travel laptop", "/fixture/older");
        laptop.helperVersion = "v1.5.49";
        laptop.projects[0].name = "Weekend planner";
        laptop.threads = [{ id: "demo-plan", cwd: "/fixture/older", title: "Draft the weekend itinerary", status: "idle", hasUnreadTurn: false }];
        state.remoteProjectInventories.set(__fixtureHost, desktop);
        state.remoteProjectInventories.set(__fixtureOlderHost, laptop);
        for (const id of [__fixtureHost, __fixtureOlderHost]) state.hostConnectivity.set(id, { available: true, checkedAt: Date.now() });
        localStorage.setItem("codex-remote-mobile-host-names-v1", JSON.stringify({ [__fixtureHost]: "Studio desktop", [__fixtureOlderHost]: "Travel laptop" }));
        localStorage.setItem("codex-remote-mobile-native-host-names-v1", JSON.stringify({ [__fixtureHost]: "Studio desktop", [__fixtureOlderHost]: "Travel laptop" }));
        state.hostDiscoveryDirty = true;
      });
      await page.evaluate(() => {
        __crmpBrowserFixture.state.settingsOpen = true;
        __crmpBrowserFixture.state.deviceDetailsOpen = false;
        __crmpBrowserFixture.state.featureOpen = { cleanup: true, updates: true, diagnostics: true };
        __fixtureUpdateStatus = { state: "current", version: "v1.5.49", details: { installedVersion: "v1.5.49", lastCheckedAt: Date.now(), historyAvailable: true, history: [{ at: Date.now(), state: "checked", version: "v1.5.49" }] } };
        globalThis.dispatchEvent(new CustomEvent("chatgpt-remote-update-status", { detail: __fixtureUpdateStatus }));
      });
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      await panel.screenshot({ path: screenshotPath.replace(/\.png$/u, "-features.png") });
      await page.evaluate(() => {
        __crmpBrowserFixture.state.featureOpen = {};
        __crmpBrowserFixture.render();
      });
      await panel.screenshot({ path: screenshotPath.replace(/\.png$/u, "-settings.png") });
    }
    await page.emulateMedia({ reducedMotion: "reduce" });
    assert.ok(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches));
    await page.evaluate(() => {
      __crmpBrowserFixture.state.settingsOpen = false;
      __crmpBrowserFixture.state.deviceDetailsOpen = false;
      __fixtureUpdateStatus = { state: "current", version: "v1.5.49", canQueue: false };
      globalThis.dispatchEvent(new CustomEvent("chatgpt-remote-update-status", { detail: __fixtureUpdateStatus }));
    });
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    if (screenshotPath) await panel.screenshot({ path: screenshotPath });
    // A separate browser profile and full document reload exercise the normal
    // production install hook. No live Codex executable or user profile is used.
    const lifecycleContext = await browser.newContext();
    const lifecyclePage = await lifecycleContext.newPage();
    lifecyclePage.setDefaultTimeout(6000);
    lifecyclePage.on("pageerror", error => errors.push(error.message));
    await lifecyclePage.route("http://connection-lifecycle.invalid/**", route => route.fulfill({ contentType: "text/html", body: '<!doctype html><html><body><nav style="width:320px"><button aria-label="Project sidebar options" hidden></button><div id="native-list"><div id="native-project" data-sidebar-project-kind="remote" role="listitem"><div role="button" data-app-action-sidebar-project-collapsed="false">Empty project</div></div></div></nav></body></html>' }));
    const bootLifecycle = async () => {
      await lifecyclePage.evaluate(() => {
        globalThis.__lifecycleHost = "remote-control:" + "env" + "_browser_lifecycle";
        globalThis.__lifecycleCatalog = [];
        globalThis.__lifecycleStatus = { available: true, authRequired: false, accessRequired: false, clientAuthorized: false };
        globalThis.__CODEX_REMOTE_MOBILE_CONFIG__ = { localDisplayName: "Fixture local" };
        localStorage.setItem("codex-remote-mobile-auto-register-enabled-v1", "false");
        localStorage.setItem("codex-remote-mobile-auto-archive-enabled-v1", "false");
        globalThis.electronBridge = { getSharedObjectSnapshotValue: key => key === "remote_control_connections" ? __lifecycleCatalog : key === "remote_control_connections_state" ? __lifecycleStatus : undefined };
        document.getElementById("native-project").__reactFiber$fixture = { memoizedProps: { group: { projectKind: "remote", projectId: "fixture-empty", hostId: __lifecycleHost, hostDisplayName: "Remote device", cwd: "/fixture/empty", label: "Empty project" } }, memoizedState: null, return: null, updateQueue: null };
      });
      await lifecyclePage.evaluate(source);
    };
    await lifecyclePage.goto("http://connection-lifecycle.invalid/");
    await bootLifecycle();
    const lifecyclePanel = lifecyclePage.locator("#codex-remote-mobile-project-panel");
    await lifecyclePanel.locator(".crmp-inventory-status").filter({ hasText: "authorize this computer" }).waitFor();
    await lifecyclePage.evaluate(() => {
      __lifecycleStatus = { ...__lifecycleStatus, clientAuthorized: true };
      __lifecycleCatalog = [{ hostId: __lifecycleHost, displayName: "Named test workstation", online: true, autoConnect: true }, { hostId: "remote-control:" + "env" + "_browser_empty", displayName: "Device without rows", online: true, autoConnect: true }];
    });
    await lifecyclePanel.locator(".crmp-chip").filter({ hasText: "Named test workstation" }).waitFor();
    await lifecyclePanel.locator(".crmp-chip").filter({ hasText: "Device without rows" }).waitFor();
    assert.equal(await lifecyclePanel.locator(".crmp-inventory-status").filter({ hasText: "authorize this computer" }).count(), 0);
    await lifecyclePage.reload();
    await bootLifecycle();
    await lifecyclePanel.locator(".crmp-chip").filter({ hasText: "Named test workstation" }).waitFor();
    await lifecyclePanel.locator(".crmp-inventory-status").filter({ hasText: "authorize this computer" }).waitFor();
    if (screenshotPath) await lifecyclePanel.screenshot({ path: screenshotPath.replace(/\.png$/u, "-authorization.png") });

    // Keep failure and truncation checks in a clean browser profile. The
    // mounted React fiber is the only runtime discovery fixture; all request
    // responses below are local in-memory values.
    const retainedContext = await browser.newContext();
    const retainedPage = await retainedContext.newPage();
    retainedPage.setDefaultTimeout(6000);
    retainedPage.on("pageerror", error => errors.push(error.message));
    await retainedPage.route("http://retained-inventory.invalid/**", route => route.fulfill({ contentType: "text/html", body: '<!doctype html><html><body><nav style="width:320px"><button aria-label="Project sidebar options" hidden></button><div id="native-list"><div id="native-project" data-sidebar-project-kind="remote" role="listitem"><div role="button" data-app-action-sidebar-project-collapsed="false">Retained project</div></div></div></nav></body></html>' }));
    await retainedPage.goto("http://retained-inventory.invalid/");
    await retainedPage.evaluate(() => {
      globalThis.__retainedHost = "remote-control:" + "env" + "_browser_retained";
      globalThis.__CODEX_REMOTE_MOBILE_CONFIG__ = { localDisplayName: "Fixture local" };
      localStorage.setItem("codex-remote-mobile-auto-register-enabled-v1", "false");
      localStorage.setItem("codex-remote-mobile-auto-archive-enabled-v1", "false");
      const project = document.getElementById("native-project");
      project.setAttribute("data-app-action-sidebar-project-list-id", "retained-project");
      project.__reactFiber$fixture = { memoizedProps: { group: { projectKind: "remote", projectId: "retained-project", hostId: __retainedHost, hostDisplayName: "Retained device", cwd: "/fixture/retained", label: "Retained project" } }, memoizedState: null, return: null, updateQueue: null };
      globalThis.__retainedProject = project;
    });
    await retainedPage.evaluate(fixtureSource);
    await retainedPage.evaluate(() => __crmpBrowserFixture.install());
    await retainedPage.evaluate(async () => {
      const state = __crmpBrowserFixture.state;
      if (state.inventoryHydrationTimer !== null) clearTimeout(state.inventoryHydrationTimer);
      state.inventoryHydrationTimer = null;
      if (state.inventoryHydrationPromise) await state.inventoryHydrationPromise;
      state.inventoryHydrationStarted = true;
      state.inventoryHydrationDirty = false;
    });
    const retainedFailure = await retainedPage.evaluate(async () => {
      const fixture = __crmpBrowserFixture;
      const state = fixture.state;
      const fetchedAt = Date.now() - 1000;
      const oldThread = { cwd: "/fixture/retained", id: "retained-old", status: "idle", title: "Retained chat" };
      state.threadInventories.set(__retainedHost, { error: null, fetchedAt, hostId: __retainedHost, pages: 1, retryAt: 0, threads: [oldThread], truncated: false });
      state.remoteRuntimeCache.clear();
      state.remoteRuntimeScannedAt = 0;
      globalThis.__retainedCalls = [];
      const runtime = { requestClient: { sendRequest: async method => { __retainedCalls.push(method); if (method === "thread/list") throw new Error("device unavailable"); throw new Error(`Unexpected fixture request: ${method}`); } } };
      __retainedProject.__reactFiber$fixture.memoizedState = [{ hostId: __retainedHost, requestClient: runtime.requestClient }];
      state.remoteRuntimeCache.set(__retainedHost, runtime);
      state.remoteRuntimeScannedAt = Date.now();
      await fixture.hydrateNativeInventory(true, state.discoveryGeneration);
      const current = state.threadInventories.get(__retainedHost);
      return { calls: __retainedCalls, error: current.error, fetchedAt: current.fetchedAt, ids: current.threads.map(thread => thread.id), truncated: current.truncated, hydrationError: state.inventoryHydrationError };
    });
    assert.deepEqual(retainedFailure.calls, ["thread/list"], "a direct failed inventory must make one bounded request");
    assert.equal(retainedFailure.error, "device unavailable");
    assert.equal(retainedFailure.fetchedAt < Date.now(), true, "a failed inventory must retain its prior timestamp");
    assert.deepEqual(retainedFailure.ids, ["retained-old"], "a failed inventory must retain the last valid rows");
    assert.equal(retainedFailure.truncated, false, "a failed refresh must preserve a previously complete snapshot");
    assert.match(retainedFailure.hydrationError, /device unavailable/u);

    const retainedTruncation = await retainedPage.evaluate(async () => {
      const fixture = __crmpBrowserFixture;
      const state = fixture.state;
      if (state.inventoryHydrationTimer !== null) clearTimeout(state.inventoryHydrationTimer);
      state.inventoryHydrationTimer = null;
      state.inventoryHydrationDirty = false;
      state.inventoryHydrationStarted = true;
      const priorFetchedAt = Date.now() - 2000;
      state.threadInventories.set(__retainedHost, { error: null, fetchedAt: priorFetchedAt, hostId: __retainedHost, pages: 1, retryAt: 0, threads: [{ cwd: "/fixture/retained", id: "retained-old", status: "idle", title: "Retained chat" }], truncated: false });
      globalThis.__retainedPageCount = 0;
      const runtime = { requestClient: { sendRequest: async method => {
        if (method !== "thread/list") throw new Error(`Unexpected fixture request: ${method}`);
        __retainedPageCount += 1;
        return { data: [{ cwd: "/fixture/retained", id: `truncated-${__retainedPageCount}`, status: "idle", title: `Page ${__retainedPageCount}` }], nextCursor: `cursor-${__retainedPageCount}` };
      } } };
      __retainedProject.__reactFiber$fixture.memoizedState = [{ hostId: __retainedHost, requestClient: runtime.requestClient }];
      state.remoteRuntimeCache.set(__retainedHost, runtime);
      state.remoteRuntimeScannedAt = Date.now();
      await fixture.hydrateNativeInventory(true, state.discoveryGeneration);
      const current = state.threadInventories.get(__retainedHost);
      return { pages: __retainedPageCount, attemptTruncated: current.attemptTruncated, error: current.error, fetchedAt: current.fetchedAt, ids: current.threads.map(thread => thread.id), truncated: current.truncated, hydrationTruncated: state.inventoryHydrationTruncated };
    });
    assert.equal(retainedTruncation.pages, 200, "a bounded browser fixture must reach the renderer page limit");
    assert.equal(retainedTruncation.attemptTruncated, true, "a bounded pagination attempt must be marked incomplete");
    assert.equal(retainedTruncation.error, "thread/list returned an incomplete inventory");
    assert.equal(retainedTruncation.fetchedAt < Date.now(), true, "a truncated inventory must retain its prior timestamp");
    assert.deepEqual(retainedTruncation.ids, ["retained-old"], "a truncated inventory must retain the last valid rows");
    assert.equal(retainedTruncation.truncated, false, "a truncated attempt must not discard a prior complete snapshot");
    assert.equal(retainedTruncation.hydrationTruncated, true);

    // A task delivered by the peer's publisher remains actionable even when
    // this renderer has no direct runtime or authoritative thread-list entry.
    const publisherNavigation = await retainedPage.evaluate(async () => {
      const fixture = __crmpBrowserFixture;
      const state = fixture.state;
      const hostId = __retainedHost;
      const conversationId = "publisher-only-thread";
      state.threadInventories.delete(hostId);
      state.verifiedThreadIds.delete(hostId);
      state.remoteRuntimeCache.clear();
      state.remoteRuntimeScannedAt = 0;
      state.hostConnectivity.set(hostId, { available: true, checkedAt: Date.now() });
      state.remoteProjectInventories.set(hostId, {
        error: null,
        fetchedAt: Date.now(),
        generatedAt: Date.now(),
        hostDisplayName: "Published device",
        pending: false,
        projects: [{ cwd: "/fixture/retained", name: "Retained project", rootPaths: ["/fixture/retained"] }],
        projectsAuthoritative: true,
        publisherVersion: 53,
        retryAt: 0,
        tasks: new Map(),
        threads: [{ cwd: "/fixture/retained", id: conversationId, projectId: null, status: "idle", title: "Publisher only chat" }],
        threadsAuthoritative: true,
        threadScope: "user-visible",
        threadScopeGeneratedAt: Date.now(),
      });
      globalThis.__publisherNavigationCalls = [];
      globalThis.__publisherNavigationBridge = {
        navigate: () => {},
        navigateToLocalConversation: (id, targetHostId) => { __publisherNavigationCalls.push({ conversationId: id, hostId: targetHostId }); },
      };
      __retainedProject.__reactFiber$fixture.memoizedProps.navigationBridge = __publisherNavigationBridge;
      state.navigationBridge = null;
      state.hostDiscoveryCache = { availability: new Map(), names: new Map(), registeredProjects: new Map(), runtimes: new Map() };
      state.hostDiscoveryDirty = false;
      state.hostDiscoveryScannedAt = Date.now();
      state.remoteRuntimeScannedAt = Date.now();
      state.filter = "all";
      state.hostDiscoveryDirty = true;
      fixture.render();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      const task = [...document.querySelectorAll(".crmp-task")].find(item => item.textContent === "Publisher only chat");
      if (!task) return { taskFound: false, calls: __publisherNavigationCalls, model: fixture.collectModel().tasks.map(item => ({ hostId: item.hostId, title: item.title })) };
      task.click();
      await new Promise(resolve => setTimeout(resolve, 0));
      return { taskFound: true, calls: __publisherNavigationCalls };
    });
    const retainedHost = await retainedPage.evaluate(() => __retainedHost);
    assert.deepEqual(publisherNavigation, { taskFound: true, calls: [{ conversationId: "publisher-only-thread", hostId: retainedHost }] }, "A publisher-only remote task must navigate to its conversation on the owning host");

    const focusThrottle = await retainedPage.evaluate(async () => {
      const fixture = __crmpBrowserFixture;
      const state = fixture.state;
      if (state.inventoryHydrationTimer !== null) clearTimeout(state.inventoryHydrationTimer);
      state.inventoryHydrationTimer = null;
      state.inventoryHydrationStarted = true;
      state.inventoryHydrationDirty = false;
      __retainedProject.__reactFiber$fixture.memoizedState = null;
      state.remoteRuntimeCache.clear();
      state.remoteRuntimeScannedAt = 0;
      state.remoteProjectInventories.set(__retainedHost, { error: null, fetchedAt: Date.now() - 181000, generatedAt: Date.now() - 181000, hostDisplayName: "Retained stale device", pending: false, projects: [{ cwd: "/fixture/retained", name: "Retained project", rootPaths: ["/fixture/retained"] }], projectsAuthoritative: true, retryAt: 0, tasks: new Map(), threads: [], threadsAuthoritative: true });
      state.healthRefreshUntil = 0;
      window.dispatchEvent(new Event("focus"));
      const firstRefresh = state.deviceRefreshPromise;
      const firstStartedAt = state.deviceRefreshLastStartedAt;
      await firstRefresh;
      const firstGeneration = state.deviceRefreshGeneration;
      window.dispatchEvent(new Event("focus"));
      await Promise.resolve();
      return { firstStarted: firstStartedAt > 0, firstGeneration, secondGeneration: state.deviceRefreshGeneration, pending: state.deviceRefreshPending };
    });
    assert.equal(focusThrottle.firstStarted, true, "a visible focus must refresh stale device data");
    assert.equal(focusThrottle.secondGeneration, focusThrottle.firstGeneration, "focus refreshes must be throttled during the cooldown");
    assert.equal(focusThrottle.pending, false);

    // A frame is coalesced to one render, and all event/focus listeners are
    // removed by uninstall. This also exercises the real mounted teardown
    // path after pending inventory work has settled.
    const teardown = await retainedPage.evaluate(async () => {
      const fixture = __crmpBrowserFixture;
      const state = fixture.state;
      if (state.scheduledFrame !== null) cancelAnimationFrame(state.scheduledFrame);
      state.scheduledFrame = null;
      if (state.inventoryHydrationTimer !== null) clearTimeout(state.inventoryHydrationTimer);
      state.inventoryHydrationTimer = null;
      state.inventoryHydrationStarted = true;
      state.inventoryHydrationDirty = false;
      const before = state.counters.renders;
      for (let index = 0; index < 100; index += 1) fixture.schedule();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      const renderDelta = state.counters.renders - before;
      const report = fixture.uninstall();
      const afterUninstall = state.counters.renders;
      window.dispatchEvent(new Event("focus"));
      window.dispatchEvent(new Event("storage"));
      document.dispatchEvent(new Event("visibilitychange"));
      fixture.schedule();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return {
        active: state.active,
        disposed: state.disposed,
        observer: state.observer,
        mountObserver: state.mountObserver,
        panelPresent: Boolean(document.getElementById("codex-remote-mobile-project-panel")),
        liveRegionPresent: Boolean(document.querySelector(".crmp-sr-only[role=status]")),
        renderDelta,
        postUninstallRenderDelta: state.counters.renders - afterUninstall,
        reportActive: report.active,
      };
    });
    assert.equal(teardown.renderDelta, 1, "repeated schedule calls must coalesce to one animation frame");
    assert.deepEqual({ active: teardown.active, disposed: teardown.disposed, observer: teardown.observer, mountObserver: teardown.mountObserver, panelPresent: teardown.panelPresent, liveRegionPresent: teardown.liveRegionPresent, postUninstallRenderDelta: teardown.postUninstallRenderDelta }, { active: false, disposed: true, observer: null, mountObserver: null, panelPresent: false, liveRegionPresent: false, postUninstallRenderDelta: 0 }, "uninstall must tear down listeners, DOM, and future renders");
    assert.equal(teardown.reportActive, false);
    await retainedContext.close();

    // Reinstall the same renderer closure while two remote reads are still
    // pending. A late successful read and a late failed read must both be
    // ignored after uninstall invalidates that generation.
    const raceContext = await browser.newContext();
    const racePage = await raceContext.newPage();
    racePage.setDefaultTimeout(6000);
    racePage.on("pageerror", error => errors.push(error.message));
    await racePage.route("http://reinstall-race.invalid/**", route => route.fulfill({ contentType: "text/html", body: '<!doctype html><html><body><nav style="width:320px"><button aria-label="Project sidebar options" hidden></button><div id="native-list"><div id="native-project" data-sidebar-project-kind="remote" role="listitem"><div role="button" data-app-action-sidebar-project-collapsed="false">Race project</div></div></div></nav></body></html>' }));
    await racePage.goto("http://reinstall-race.invalid/");
    await racePage.evaluate(() => {
      globalThis.__raceHostSuccess = "remote-control:" + "env" + "_browser_late_success";
      globalThis.__raceHostFailure = "remote-control:" + "env" + "_browser_late_failure";
      globalThis.__CODEX_REMOTE_MOBILE_CONFIG__ = { localDisplayName: "Fixture local" };
      localStorage.setItem("codex-remote-mobile-auto-register-enabled-v1", "false");
      localStorage.setItem("codex-remote-mobile-auto-archive-enabled-v1", "false");
      const project = document.getElementById("native-project");
      project.setAttribute("data-app-action-sidebar-project-list-id", "race-project");
      project.__reactFiber$fixture = { memoizedProps: { group: { projectKind: "remote", projectId: "race-project", hostId: __raceHostSuccess, hostDisplayName: "Race device", cwd: "/fixture/race", label: "Race project" } }, memoizedState: null, return: null, updateQueue: null };
      globalThis.__raceProject = project;
    });
    await racePage.evaluate(fixtureSource);
    await racePage.evaluate(() => __crmpBrowserFixture.install());
    await racePage.evaluate(async () => {
      const fixture = __crmpBrowserFixture;
      const state = fixture.state;
      if (state.inventoryHydrationTimer !== null) clearTimeout(state.inventoryHydrationTimer);
      state.inventoryHydrationTimer = null;
      if (state.inventoryHydrationPromise) await state.inventoryHydrationPromise;
      state.inventoryHydrationStarted = true;
      const makeOldInventory = hostId => ({ error: null, fetchedAt: Date.now() - 1000, generatedAt: Date.now() - 1000, hostDisplayName: "Prior snapshot", pending: false, projects: [], projectsAuthoritative: true, publisherVersion: 53, retryAt: 0, tasks: new Map(), threads: [], threadsAuthoritative: true });
      state.remoteProjectInventories.set(__raceHostSuccess, makeOldInventory(__raceHostSuccess));
      state.remoteProjectInventories.set(__raceHostFailure, makeOldInventory(__raceHostFailure));
      const oldSuccessHome = new Promise((resolve, reject) => { globalThis.__resolveOldSuccess = resolve; globalThis.__rejectOldSuccess = reject; });
      const oldFailureHome = new Promise((resolve, reject) => { globalThis.__resolveOldFailure = resolve; globalThis.__rejectOldFailure = reject; });
      const oldPayload = hostDisplayName => ({ generatedAt: new Date().toISOString(), hostDisplayName, projects: [{ cwd: "/fixture/race", name: "Old response", rootPaths: ["/fixture/race"] }], publisherVersion: 53, schemaVersion: 1, tasks: [], threadScope: "user-visible", threadScopeGeneratedAt: new Date().toISOString(), threads: [] });
      const encode = value => btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(value))));
      const oldRuntime = (home, payload, failure = false) => ({ requestClient: { sendRequest: async method => {
        if (method === "config/read") return home;
        if (method === "fs/readFile") { if (failure) throw new Error("unexpected old file read"); return { dataBase64: encode(payload) }; }
        throw new Error(`Unexpected fixture request: ${method}`);
      } } });
      const oldSuccess = oldRuntime(oldSuccessHome, oldPayload("Late old success"));
      const oldFailure = oldRuntime(oldFailureHome, oldPayload("Should not appear"), true);
      state.remoteRuntimeCache.set(__raceHostSuccess, oldSuccess);
      state.remoteRuntimeCache.set(__raceHostFailure, oldFailure);
      globalThis.__oldReinstallFixture = fixture;
      globalThis.__oldReinstallPromise = fixture.scheduleRemoteProjectInventory(new Map([[__raceHostSuccess, oldSuccess], [__raceHostFailure, oldFailure]]), true, state.discoveryGeneration);
    });
    await racePage.waitForTimeout(0);
    await racePage.evaluate(() => {
      const fixture = __oldReinstallFixture;
      // Remove the runtime from the mounted graph so install() cannot start a
      // second request while the intentionally delayed old requests settle.
      __raceProject.__reactFiber$fixture.memoizedState = null;
      fixture.uninstall();
      fixture.install();
      const state = fixture.state;
      const freshInventory = (name) => ({ error: null, fetchedAt: Date.now(), generatedAt: Date.now(), hostDisplayName: name, pending: false, projects: [{ cwd: "/fixture/race", name: "Fresh after reinstall", rootPaths: ["/fixture/race"] }], projectsAuthoritative: true, publisherVersion: 53, retryAt: 0, tasks: new Map(), threads: [], threadsAuthoritative: true });
      state.remoteRuntimeCache.clear();
      state.remoteProjectInventories.set(__raceHostSuccess, freshInventory("Fresh success device"));
      state.remoteProjectInventories.set(__raceHostFailure, freshInventory("Fresh failure device"));
    });
    const reinstallRace = await racePage.evaluate(async () => {
      __resolveOldSuccess({ codexHome: "C:\\Fixture\\late-old-success\\.codex" });
      __rejectOldFailure(new Error("late old failure"));
      await __oldReinstallPromise;
      const state = __oldReinstallFixture.state;
      return {
        disposed: state.disposed,
        active: state.active,
        success: { name: state.remoteProjectInventories.get(__raceHostSuccess)?.hostDisplayName, error: state.remoteProjectInventories.get(__raceHostSuccess)?.error },
        failure: { name: state.remoteProjectInventories.get(__raceHostFailure)?.hostDisplayName, error: state.remoteProjectInventories.get(__raceHostFailure)?.error },
      };
    });
    assert.deepEqual(reinstallRace, { disposed: false, active: true, success: { name: "Fresh success device", error: null }, failure: { name: "Fresh failure device", error: null } }, "late success and failure must be ignored after same-closure uninstall and reinstall");
    await racePage.evaluate(() => __oldReinstallFixture.uninstall());
    await raceContext.close();

    await lifecycleContext.close();
    assert.deepEqual(errors, [], "the real renderer must not raise browser errors");
    console.log(JSON.stringify({ nativeConnectionLifecycle: true, nativeLabelsWithoutRows: true, fullDocumentReloadRetainsLabels: true, authorizationPauseVisible: true, settingsContainUpdatesAndHealth: true, missingUpdaterRecoveryBothViews: true, guidedConnectionTroubleshooting: true, transferDiagnosticsAllowlisted: true, featureControls: true, compactRefreshControl: true, directTaskNavigation: true, publisherTaskNavigation: true, sharedAliasSaveReset: true, sharedAliasReload: true, sharedAliasTombstone: true, sharedAliasFilterOrdering: true, caretPreserved: true, healthRefreshCoalesced: true, diagnosticCopyAndNativeSave: true, diagnosticCancelAndError: true, directFailureRowsRetained: true, directTruncatedRowsRetained: true, scheduleFrameCoalesced: true, focusRefreshThrottled: true, focusListenerTeardown: true, uninstallTeardown: true, lateSuccessFailureIgnoredAfterReinstall: true, uxStates: 10, themes: 2, sidebarWidths: [280,320,400], scaling: [1,2], fixtureTextContrast: true, stableAnnouncements: true, focusRestored: true, realChromium: true, realModelAndRender: true, neutralName: true, metadataArrival: true, reinjection: true, updateEventBothTargets: true, keyboardQueue: true, nativeViewUpdate: true, cancel: true, unrelatedMutations: 200, extraRenders: after.renders - before.renders, extraHostScans: after.hostDiscoveryScans - before.hostDiscoveryScans }));
  } finally { await browser.close(); }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
