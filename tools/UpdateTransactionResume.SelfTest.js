"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { once } = require("node:events");
const { spawn, spawnSync } = require("node:child_process");

const repositoryRoot = path.resolve(__dirname, "..");
const helper = path.join(repositoryRoot, "windows", "update-transaction.js");
const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "chatgpt-remote-resume-test-"));
const hookPath = path.join(temporaryRoot, "transaction-hook.js");

function sha256File(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function writeFile(file, contents) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, contents, "utf8");
}

function writeManifest(root) {
  const excluded = new Set([".chatgpt-remote-prepared.json", ".chatgpt-remote-release.zip", "RELEASE-MANIFEST.sha256"]);
  const files = [];
  function visit(directory) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(absolute);
      else if (entry.isFile() && !excluded.has(entry.name)) files.push(absolute);
    }
  }
  visit(root);
  files.sort((left, right) => left.localeCompare(right));
  const lines = files.map((file) => `${sha256File(file)} *${path.relative(root, file).split(path.sep).join("/")}`);
  writeFile(path.join(root, "RELEASE-MANIFEST.sha256"), `${lines.join("\n")}\n`);
}

function invoke(arguments_, environment = {}) {
  const result = spawnSync(process.execPath, [helper, ...arguments_], {
    encoding: "utf8",
    env: { ...process.env, ...environment },
    timeout: 30_000,
    windowsHide: true,
  });
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return JSON.parse(result.stdout);
}

function createFixture(name) {
  const root = path.join(temporaryRoot, name);
  const install = path.join(root, "install");
  const prepared = path.join(root, "prepared");
  const state = path.join(root, "state");
  const journal = path.join(state, "transaction.json");
  const backup = path.join(state, "rollback");
  const events = path.join(root, "events.jsonl");
  fs.mkdirSync(install, { recursive: true });
  fs.mkdirSync(prepared, { recursive: true });
  writeFile(path.join(install, "00-alpha.txt"), "old alpha\n");
  writeFile(path.join(install, "VERSION"), "v1.0.0\n");
  writeFile(path.join(install, "removed.txt"), "remove me\n");
  writeManifest(install);
  writeFile(path.join(prepared, "00-alpha.txt"), "new alpha\n");
  writeFile(path.join(prepared, "10-added.txt"), "new file\n");
  writeFile(path.join(prepared, "VERSION"), "v2.0.0\n");
  writeManifest(prepared);
  const archive = path.join(prepared, ".chatgpt-remote-release.zip");
  fs.writeFileSync(archive, "fixture archive bytes", "utf8");
  const archiveHash = sha256File(archive);
  invoke([
    "seal-prepared", "--prepared-root", prepared, "--platform", "Windows-x64",
    "--version", "v2.0.0", "--archive-sha256", archiveHash,
  ]);
  return { archiveHash, backup, events, install, journal, prepared, root };
}

function applyArguments(fixture) {
  return [
    "apply", "--install-root", fixture.install, "--prepared-root", fixture.prepared,
    "--journal-path", fixture.journal, "--backup-root", fixture.backup,
    "--platform", "Windows-x64", "--version", "v2.0.0", "--archive-sha256", fixture.archiveHash,
  ];
}

function hookEnvironment(fixture, pauseCount = null) {
  return {
    NODE_OPTIONS: `--require=${hookPath}`,
    CHATGPT_REMOTE_TEST_EVENTS: fixture.events,
    CHATGPT_REMOTE_TEST_JOURNAL: fixture.journal,
    ...(pauseCount === null ? {} : { CHATGPT_REMOTE_TEST_PAUSE_COUNT: String(pauseCount) }),
  };
}

function readJournal(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); }
  catch { return null; }
}

async function pauseApplyAtCheckpoint(fixture, completedOperations) {
  const child = spawn(process.execPath, [helper, ...applyArguments(fixture)], {
    env: { ...process.env, ...hookEnvironment(fixture, completedOperations) },
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const deadline = Date.now() + 15_000;
  let journal;
  while (Date.now() < deadline) {
    journal = readJournal(fixture.journal);
    if (journal?.completedOperations === completedOperations) break;
    if (child.exitCode !== null) throw new Error(`Apply exited before checkpoint ${completedOperations}: ${stderr}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.equal(journal?.completedOperations, completedOperations, `checkpoint ${completedOperations} was not durable`);
  child.kill("SIGKILL");
  await once(child, "close");
  return journal;
}

function readEvents(file) {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, "utf8").split(/\r?\n/u).filter(Boolean).map((line) => JSON.parse(line));
}

function assertUpdated(fixture) {
  assert.equal(fs.readFileSync(path.join(fixture.install, "00-alpha.txt"), "utf8"), "new alpha\n");
  assert.equal(fs.readFileSync(path.join(fixture.install, "10-added.txt"), "utf8"), "new file\n");
  assert.equal(fs.readFileSync(path.join(fixture.install, "VERSION"), "utf8"), "v2.0.0\n");
  assert.equal(fs.existsSync(path.join(fixture.install, "removed.txt")), false);
  assert.equal(fs.existsSync(fixture.journal), false);
}

writeFile(hookPath, `
"use strict";
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const key = (value) => process.platform === "win32" ? path.resolve(value).toLowerCase() : path.resolve(value);
const journalKey = key(process.env.CHATGPT_REMOTE_TEST_JOURNAL);
const originalRename = fs.renameSync;
fs.renameSync = function(source, destination) {
  const result = originalRename.apply(this, arguments);
  let completed = null;
  if (key(destination) === journalKey) {
    try { completed = JSON.parse(fs.readFileSync(destination, "utf8")).completedOperations; } catch {}
  }
  if (process.env.CHATGPT_REMOTE_TEST_EVENTS) {
    fs.appendFileSync(process.env.CHATGPT_REMOTE_TEST_EVENTS, JSON.stringify({ destination: path.resolve(destination), completed }) + "\\n");
  }
  if (completed !== null && completed === Number(process.env.CHATGPT_REMOTE_TEST_PAUSE_COUNT)) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
  }
  return result;
};
childProcess.spawnSync = function() {
  throw new Error("Transaction replacement attempted to launch a nested process.");
};
`);

(async () => {
  try {
    const renameRoot = path.join(temporaryRoot, "native-rename");
    fs.mkdirSync(renameRoot);
    const renameSource = path.join(renameRoot, "source.txt");
    const renameDestination = path.join(renameRoot, "destination.txt");
    writeFile(renameSource, "new\n");
    writeFile(renameDestination, "old\n");
    fs.renameSync(renameSource, renameDestination);
    assert.equal(fs.readFileSync(renameDestination, "utf8"), "new\n");
    assert.equal(fs.existsSync(renameSource), false);

    const first = createFixture("boundary-0");
    const firstJournal = await pauseApplyAtCheckpoint(first, 0);
    const operationCount = firstJournal.operations.length;
    fs.writeFileSync(first.events, "", "utf8");
    let recovered = invoke(["recover", "--journal-path", first.journal, "--install-root", first.install], hookEnvironment(first));
    assert.equal(recovered.recoveryMode, "complete-forward");
    assertUpdated(first);

    for (let checkpoint = 1; checkpoint <= operationCount; checkpoint += 1) {
      const fixture = createFixture(`boundary-${checkpoint}`);
      const journal = await pauseApplyAtCheckpoint(fixture, checkpoint);
      fs.writeFileSync(fixture.events, "", "utf8");
      recovered = invoke(["recover", "--journal-path", fixture.journal, "--install-root", fixture.install], hookEnvironment(fixture));
      assert.equal(recovered.recoveryMode, "complete-forward");
      const rewritten = new Set(readEvents(fixture.events).map((event) => path.normalize(event.destination)));
      for (const operation of journal.operations.slice(0, checkpoint)) {
        if (operation.kind === "copy") {
          assert.equal(rewritten.has(path.normalize(operation.destination)), false,
            `recovery rewrote completed operation ${operation.relative} from checkpoint ${checkpoint}`);
        }
      }
      assertUpdated(fixture);
    }

    const corrupt = createFixture("corrupt-prefix");
    const corruptJournal = await pauseApplyAtCheckpoint(corrupt, Math.min(2, operationCount));
    assert.equal(corruptJournal.operations[0].kind, "copy");
    fs.writeFileSync(corruptJournal.operations[0].destination, "tampered after checkpoint\n", "utf8");
    fs.writeFileSync(corrupt.events, "", "utf8");
    recovered = invoke(["recover", "--journal-path", corrupt.journal, "--install-root", corrupt.install], hookEnvironment(corrupt));
    assert.equal(recovered.recoveryMode, "complete-forward");
    const corruptEvents = readEvents(corrupt.events);
    assert.ok(corruptEvents.some((event) => event.completed === 0), "recovery did not durably rewind the damaged prefix");
    assert.ok(corruptEvents.some((event) => path.normalize(event.destination) === path.normalize(corruptJournal.operations[0].destination)),
      "recovery did not repair the first damaged destination");
    assertUpdated(corrupt);

    process.stdout.write(`${JSON.stringify({
      ok: true,
      atomicExistingDestinationRename: true,
      completedPrefixNotRewritten: true,
      corruptionRewindsDurably: true,
      interruptBoundaries: operationCount + 1,
      nestedReplacementProcesses: 0,
    })}\n`);
  } finally {
    fs.rmSync(temporaryRoot, { recursive: true, force: true });
  }
})().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
