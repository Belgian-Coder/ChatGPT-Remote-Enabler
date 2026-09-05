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
const fixtureSource = source.replace("  return install();\n})();", "  globalThis.__crmpBrowserFixture = { state, install, render, collectModel };\n})();");
assert.notEqual(fixtureSource, source, "The fixture must expose the real renderer entrypoints.");

async function main() {
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
      globalThis.__CODEX_REMOTE_MOBILE_CONFIG__ = { localDisplayName: "Local device", hostDisplayNames: {} };
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
    await panel.getByRole("button", { name: "Native views", exact: true }).click();
    await updateButton.waitFor();
    await panel.getByRole("button", { name: "Mobile projects", exact: true }).click();

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
    for (const width of [280, 320]) {
      await page.locator("nav").evaluate((element, value) => { element.style.width = `${value}px`; }, width);
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(resolve)));
      const controls = await panel.locator("button").evaluateAll(elements => elements.filter(element => element.getBoundingClientRect().width > 0).map(element => ({ text: element.textContent, client: element.clientWidth, scroll: element.scrollWidth, left: element.getBoundingClientRect().left, right: element.getBoundingClientRect().right })));
      for (const control of controls) {
        assert.ok(control.scroll <= control.client + 1, `Button text clipped at ${width}px: ${control.text}`);
        assert.ok(control.left >= 0 && control.right <= width, `Button exceeds sidebar at ${width}px: ${control.text}`);
      }
    }
    await page.locator("nav").evaluate(element => { element.style.width = "288px"; });
    const screenshotIndex = process.argv.indexOf("--screenshot");
    if (screenshotIndex >= 0) await page.screenshot({ path: path.resolve(process.argv[screenshotIndex + 1]), clip: { x: 0, y: 0, width: 300, height: 650 } });
    assert.deepEqual(errors, [], "the real renderer must not raise browser errors");
    console.log(JSON.stringify({ realChromium: true, realModelAndRender: true, neutralName: true, metadataArrival: true, reinjection: true, updateEventBothTargets: true, keyboardQueue: true, nativeViewUpdate: true, cancel: true, unrelatedMutations: 200, extraRenders: after.renders - before.renders, extraHostScans: after.hostDiscoveryScans - before.hostDiscoveryScans }));
  } finally { await browser.close(); }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
