"use strict";

// Isolated Chromium fixture: no app debugger, account, peer or updater access.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");
const source = fs.readFileSync(path.join(__dirname, "../windows/CodexRemoteMobileProject/renderer-mobile-project-view.js"), "utf8").replace(/\r\n/gu, "\n");
const fixture = source.replace("  return install();\n})();", "  globalThis.fixture = {state, install, render, uninstall, filterLoadedGroups};\n})();");
assert.notEqual(source, fixture);

async function main() {
  const edge = process.platform === "win32" ? path.join(process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)", "Microsoft/Edge/Application/msedge.exe") : null;
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHATGPT_REMOTE_BROWSER || (edge && fs.existsSync(edge) ? edge : undefined) });
  const errors = [];
  try {
    const page = await browser.newPage({ viewport: { width: 820, height: 860 } });
    page.setDefaultTimeout(6000);
    page.on("pageerror", error => errors.push(error.message));
    await page.route("**/*", route => {
      assert.equal(route.request().url(), "http://search-fixture.invalid/");
      return route.fulfill({ contentType: "text/html", body: `<!doctype html><html><head><style>
        :root{color-scheme:light;--color-text:#202124;--color-text-secondary:#50545c;--color-border-default:#c6c9ce;--color-background-primary:#fff;--color-background-secondary:#f5f6f8;--color-background-inverted:#e4e8ee;--color-text-tertiary:#60646c}
        *{box-sizing:border-box}body{margin:0;color:var(--color-text);background:var(--color-background-primary);font:13px Arial,sans-serif}
        nav{width:320px;padding:8px;min-height:860px;border-right:1px solid var(--color-border-default)}
        button{color:inherit;font:inherit;background:transparent;border:0;cursor:pointer}
        #composer{position:absolute;left:360px;top:40px}#native-list{margin-top:12px}
      </style></head><body><nav><button>New chat</button><div id="native-list"><div id="native-project" data-sidebar-project-kind="remote" role="listitem"><div role="button" tabindex="0" aria-expanded="false" data-app-action-sidebar-project-collapsed="true">Design project</div></div></div></nav><textarea id="composer">Keep my unsent draft</textarea></body></html>` });
    });
    await page.goto("http://search-fixture.invalid/");
    await page.evaluate(() => {
      globalThis.host = "remote-control:env_search_fixture";
      globalThis.__CODEX_REMOTE_MOBILE_CONFIG__ = { localDisplayName: "This computer", helperVersion: "v1.5.53", hostDisplayNames: {} };
      for (const key of ["auto-register", "auto-archive"]) localStorage.setItem(`codex-remote-mobile-${key}-enabled-v1`, "false");
      const project = document.getElementById("native-project");
      project.__reactFiber$fixture = { memoizedProps: { group: { projectKind: "remote", projectId: "design", hostId: host, hostDisplayName: "Studio desktop", cwd: "/fixture/design", label: "Design project" } }, memoizedState: null, return: null, updateQueue: null };
      globalThis.nativeToggles = 0;
      project.querySelector("[role=button]").addEventListener("click", () => { nativeToggles++; });
    });
    await page.evaluate(fixture);
    await page.evaluate(() => {
      const now = Date.now();
      fixture.state.remoteProjectInventories.set(host, {
        error: null, fetchedAt: now, generatedAt: now, hostDisplayName: "Studio desktop", pending: false,
        projects: [{ cwd: "/fixture/design", name: "Design project", rootPaths: ["/fixture/design"] }, { cwd: "/fixture/travel", name: "Weekend planner", rootPaths: ["/fixture/travel"] }],
        projectsAuthoritative: true, publisherVersion: 53, retryAt: 0, tasks: new Map(), threadScope: "user-visible", threadScopeGeneratedAt: now,
        threads: [
          { id: "design-layout", cwd: "/fixture/design", title: "Refine the dashboard layout", status: "idle" },
          { id: "design-tests", cwd: "/fixture/design", title: "Review accessibility checks", status: "idle" },
          { id: "weekend", cwd: "/fixture/travel", title: "Draft the weekend itinerary", status: "idle" },
        ], threadsAuthoritative: true,
      });
      fixture.state.threadInventories.set("local", { fetchedAt: now, threads: [], error: null });
      fixture.install();
    });
    const panel = page.locator("#codex-remote-mobile-project-panel");
    const search = panel.getByRole("textbox", { name: "Find projects and chats", exact: true });
    assert.equal(await panel.locator(".crmp-project-toggle").count(), 2);
    assert.equal(await panel.getByRole("button", { name: "Refine the dashboard layout", exact: true }).count(), 0, "native collapse is respected before searching");
    const collapsed = await page.evaluate(() => [...fixture.state.collapsed]);
    const before = await page.evaluate(() => ({ ...fixture.state.counters }));
    await search.fill("LAYOUT dashboard");
    await page.waitForFunction(() => fixture.state.searchQuery === "LAYOUT dashboard");
    assert.equal(await panel.locator(".crmp-task").count(), 1);
    assert.equal(await panel.locator(".crmp-task").innerText(), "Refine the dashboard layout");
    assert.equal(await panel.locator(".crmp-project-toggle").getAttribute("aria-expanded"), "true");
    assert.deepEqual(await page.evaluate(() => [...fixture.state.collapsed]), collapsed);
    assert.equal(await page.evaluate(() => nativeToggles), 0, "search does not open native projects");
    assert.equal(await page.evaluate(() => fixture.state.counters.hostDiscoveryScans), before.hostDiscoveryScans, "typing reuses the loaded model");
    assert.equal(await search.evaluate(el => document.activeElement === el), true);
    assert.equal(await search.evaluate(el => el.selectionStart), "LAYOUT dashboard".length);
    assert.equal(await panel.locator("[draggable=true]").count(), 0, "partial search results cannot be reordered");
    await panel.locator(".crmp-project-toggle").click();
    assert.equal(await panel.locator(".crmp-task").count(), 0, "search groups may collapse independently");
    await search.fill("design");
    await page.waitForFunction(() => fixture.state.searchQuery === "design");
    assert.equal(await panel.locator(".crmp-task").count(), 2, "a project-name match includes its loaded chats");
    await panel.getByRole("button", { name: "Clear search", exact: true }).click();
    assert.equal(await search.inputValue(), "");
    assert.equal(await search.evaluate(el => document.activeElement === el), true);
    assert.equal(await panel.getByRole("button", { name: "Refine the dashboard layout", exact: true }).count(), 0, "clear restores native collapse");
    await search.fill("ＷＥＥＫＥＮＤ");
    await page.waitForFunction(() => fixture.state.searchQuery === "ＷＥＥＫＥＮＤ");
    assert.equal(await panel.locator(".crmp-task").innerText(), "Draft the weekend itinerary", "Unicode compatibility and case normalization");
    await panel.getByRole("button", { name: /This device,/u }).click();
    assert.match(await panel.locator(".crmp-empty").innerText(), /No matches in loaded/);
    await panel.getByRole("button", { name: "All devices", exact: true }).click();
    await search.fill("<script>missing</script>");
    await page.waitForFunction(() => fixture.state.searchQuery === "<script>missing</script>");
    assert.match(await panel.locator(".crmp-empty").innerText(), /No matches in loaded/);
    await search.press("Escape");
    assert.equal(await search.inputValue(), "");
    // A background refresh during IME composition must retain the actual input.
    await search.dispatchEvent("compositionstart");
    await search.evaluate(el => { globalThis.composingInput = el; el.value = "weekend"; el.dispatchEvent(new InputEvent("input", { bubbles: true, isComposing: true })); fixture.render(); });
    assert.equal(await search.evaluate(el => el === composingInput), true);
    await search.dispatchEvent("compositionend");
    await page.waitForFunction(() => fixture.state.searchQuery === "weekend");
    assert.equal(await panel.locator(".crmp-task").count(), 1);
    await search.press("Escape");
    const storedValues = await page.evaluate(() => Object.values(localStorage));
    assert.ok(storedValues.every(value => !value.includes("<script>missing</script>") && !value.includes("LAYOUT dashboard")), "queries are not persisted");
    assert.equal(await page.locator("#composer").inputValue(), "Keep my unsent draft");
    const debounceBefore = await page.evaluate(() => fixture.state.counters.renders);
    await search.evaluate(el => {
      for (const value of ["r", "re", "review"]) {
        el.value = value;
        el.dispatchEvent(new InputEvent("input", { bubbles: true }));
      }
    });
    await page.waitForFunction(() => fixture.state.searchQuery === "review");
    assert.equal(await page.evaluate(() => fixture.state.counters.renders), debounceBefore + 1, "a burst of typing produces one render");
    await search.press("Escape");

    // Health shortcut reveals and focuses the actual relevant Settings section.
    await page.evaluate(() => { fixture.state.deviceRefreshLastError = "fixture error"; fixture.render(); });
    await panel.getByRole("button", { name: "Device health", exact: true }).click();
    assert.equal(await panel.locator(".crmp-devices").getAttribute("open"), "");
    assert.equal(await panel.locator(".crmp-devices > summary").evaluate(el => document.activeElement === el), true);
    const automation = panel.locator("details").filter({ has: page.locator("summary", { hasText: /^Automatic cleanup$/u }) });
    assert.equal(await automation.getAttribute("open"), null);
    await automation.locator(":scope > summary").click();
    await panel.getByRole("button", { name: "Auto-cleanup: off", exact: true }).waitFor();
    assert.equal(await page.evaluate(() => localStorage.getItem("codex-remote-mobile-auto-archive-enabled-v1")), "false");

    const screenshotIndex = process.argv.indexOf("--screenshot");
    const screenshot = screenshotIndex >= 0 ? path.resolve(process.argv[screenshotIndex + 1]) : null;
    await panel.getByRole("button", { name: "Settings", exact: true }).click();
    await search.fill("design");
    await page.waitForFunction(() => fixture.state.searchQuery === "design");
    for (const width of [280, 320, 400]) {
      await page.locator("nav").evaluate((el, width) => { el.style.width = `${width}px`; }, width);
      for (const zoom of [1, 2]) {
        await page.locator("nav").evaluate((el, zoom) => { el.style.zoom = zoom; }, zoom);
        assert.equal(await panel.evaluate(el => el.scrollWidth <= el.clientWidth + 1), true, `no panel overflow at ${width}px/${zoom}x`);
      }
    }
    await page.locator("nav").evaluate(el => { el.style.width = "320px"; el.style.zoom = 1; });
    if (screenshot) await panel.screenshot({ path: screenshot });
    await page.evaluate(() => { document.documentElement.style.cssText = "color-scheme:dark;--color-text:#e5e7eb;--color-text-secondary:#b5becb;--color-border-default:#495464;--color-background-primary:#1b222f;--color-background-secondary:#252d3a;--color-background-inverted:#3a4556;--color-text-tertiary:#abb3c0"; });
    if (screenshot) await panel.screenshot({ path: screenshot.replace(/\.png$/u, "-dark.png") });
    await search.press("Escape");
    await panel.getByRole("button", { name: "Settings", exact: true }).click();
    await page.evaluate(() => { fixture.state.deviceDetailsOpen = false; fixture.state.featureOpen.automation = false; fixture.render(); });
    if (screenshot) await panel.screenshot({ path: screenshot.replace(/\.png$/u, "-settings.png") });
    await panel.getByRole("button", { name: "Settings", exact: true }).click();
    await search.fill("pending teardown");
    await page.evaluate(() => { fixture.uninstall(); });
    assert.equal(await page.evaluate(() => fixture.state.searchTimer), null);
    assert.equal(await page.evaluate(() => fixture.state.lastRenderedModel), null);
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({ loadedSearch: true, projectAndChatMatches: true, deviceScope: true, unicode: true, nativeCollapsePreserved: true, keyboardClear: true, focusAndCaret: true, compositionPreserved: true, noSearchDiscoveryScans: true, noQueryPersistence: true, draftPreserved: true, healthShortcut: true, cleanupDisclosure: true, teardown: true, widths: [280, 320, 400], zoom: [1, 2], themes: ["light", "dark"], realChromium: true }));
  } finally { await browser.close(); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
