"use strict";

const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const windowsHelperPath = path.join(root, "windows", "git-release.js");
const macosHelperPath = path.join(root, "macos", "git-release.js");
const windowsHelper = require(windowsHelperPath);
const macosHelper = require(macosHelperPath);

assert.deepEqual(Object.keys(windowsHelper).sort(), Object.keys(macosHelper).sort(), "platform Git helpers must expose the same API");
assert.equal(fs.readFileSync(windowsHelperPath, "utf8"), fs.readFileSync(macosHelperPath, "utf8"), "platform Git helpers must remain mirrored");

function git(cwd, args, input) {
  const result = childProcess.spawnSync("git", args, {
    cwd,
    input,
    encoding: "utf8",
    env: { ...process.env, GIT_TERMINAL_PROMPT: "0", GIT_CONFIG_NOSYSTEM: "1" },
    windowsHide: true,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${result.error?.message || result.stderr}`);
  return result.stdout.trim();
}

function write(file, contents) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, contents);
}

function chmodExecutable(file) {
  try { fs.chmodSync(file, 0o755); } catch {}
}

function initRepo(parent, name) {
  const repo = path.join(parent, name);
  fs.mkdirSync(repo, { recursive: true });
  git(repo, ["init", "--quiet"]);
  git(repo, ["config", "user.email", "selftest@example.invalid"]);
  git(repo, ["config", "user.name", "Git release self-test"]);
  return repo;
}

function commit(repo, message, tag) {
  git(repo, ["add", "--all", "--force"]);
  git(repo, ["commit", "--quiet", "--allow-empty", "-m", message]);
  if (tag) git(repo, ["tag", "-a", tag, "-m", tag]);
  return git(repo, ["rev-parse", "HEAD"]);
}

function createGoodRepo(parent) {
  const repo = initRepo(parent, "good");
  write(path.join(repo, "windows", "VERSION"), "v1.0.0\n");
  write(path.join(repo, "windows", "Update-ChatGPTRemote.ps1"), "Write-Output good\n");
  write(path.join(repo, "windows", "nested", "data.txt"), "windows\n");
  write(path.join(repo, "macos", "VERSION"), "v1.0.0\n");
  write(path.join(repo, "macos", "Update-ChatGPTRemote.sh"), "#!/bin/sh\nprintf good\\n\n");
  chmodExecutable(path.join(repo, "macos", "Update-ChatGPTRemote.sh"));
  commit(repo, "v1.0.0", "v1.0.0");
  write(path.join(repo, "windows", "VERSION"), "v1.2.0\n");
  write(path.join(repo, "windows", "new.txt"), "new windows\n");
  write(path.join(repo, "macos", "VERSION"), "v1.2.0\n");
  write(path.join(repo, "macos", "new.sh"), "#!/bin/sh\nprintf new\\n\n");
  chmodExecutable(path.join(repo, "macos", "new.sh"));
  const latestCommit = commit(repo, "v1.2.0", "v1.2.0");
  git(repo, ["tag", "v9.0.0-rc.1", latestCommit]);
  return repo;
}

function readZip(file) {
  const bytes = fs.readFileSync(file);
  let end = -1;
  for (let index = bytes.length - 22; index >= Math.max(0, bytes.length - 22 - 65535); index -= 1) {
    if (bytes.readUInt32LE(index) === 0x06054b50) { end = index; break; }
  }
  assert.ok(end >= 0, "ZIP EOCD must exist");
  const count = bytes.readUInt16LE(end + 10);
  const centralSize = bytes.readUInt32LE(end + 12);
  const centralOffset = bytes.readUInt32LE(end + 16);
  assert.equal(centralOffset + centralSize, end, "ZIP central directory must be deterministic and contiguous");
  const records = [];
  let cursor = centralOffset;
  for (let index = 0; index < count; index += 1) {
    assert.equal(bytes.readUInt32LE(cursor), 0x02014b50, "ZIP central entry signature");
    const madeBy = bytes.readUInt16LE(cursor + 4);
    const method = bytes.readUInt16LE(cursor + 10);
    const crc = bytes.readUInt32LE(cursor + 16);
    const size = bytes.readUInt32LE(cursor + 24);
    const nameLength = bytes.readUInt16LE(cursor + 28);
    const extraLength = bytes.readUInt16LE(cursor + 30);
    const commentLength = bytes.readUInt16LE(cursor + 32);
    const externalAttributes = bytes.readUInt32LE(cursor + 38);
    const localOffset = bytes.readUInt32LE(cursor + 42);
    const name = bytes.subarray(cursor + 46, cursor + 46 + nameLength).toString("utf8");
    assert.equal(method, 0, "release ZIP entries must be stored");
    assert.equal(bytes.readUInt32LE(localOffset), 0x04034b50, "ZIP local entry signature");
    const localNameLength = bytes.readUInt16LE(localOffset + 26);
    const localExtraLength = bytes.readUInt16LE(localOffset + 28);
    const dataStart = localOffset + 30 + localNameLength + localExtraLength;
    const data = bytes.subarray(dataStart, dataStart + size);
    assert.equal(crypto.createHash("sha256").update(data).digest("hex").length, 64);
    records.push({ name, data, madeBy, externalAttributes, crc });
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  return records;
}

function resolve(helper, options, remotePath) {
  return helper.resolveRelease(options, { testRemotePath: remotePath });
}

function assertRejects(fn, pattern) {
  assert.throws(fn, pattern);
}

function createMaliciousRepo(parent, name, setup) {
  const repo = initRepo(parent, name);
  write(path.join(repo, "windows", "VERSION"), "v1.0.0\n");
  commit(repo, `${name}-base`);
  setup(repo);
  const tree = git(repo, ["write-tree"]);
  const maliciousCommit = git(repo, ["commit-tree", tree, "-p", "HEAD", "-m", name]);
  git(repo, ["update-ref", "refs/heads/master", maliciousCommit]);
  git(repo, ["tag", "-a", "v1.0.0", "-m", "v1.0.0"]);
  return repo;
}

function testMaliciousTrees(parent, cacheRoot) {
  const symlink = createMaliciousRepo(parent, "symlink", (repo) => {
    const object = git(repo, ["hash-object", "-w", "--stdin"], "../../outside\n");
    git(repo, ["update-index", "--add", "--cacheinfo", `120000,${object},windows/link`]);
  });
  assertRejects(() => resolve(windowsHelper, { repository: "owner/repo", platform: "Windows-x64", cacheRoot }, symlink), /symbolic link/u);

  const submodule = createMaliciousRepo(parent, "submodule", (repo) => {
    const object = git(repo, ["hash-object", "-w", "--stdin"], "submodule\n");
    const commitObject = git(repo, ["rev-parse", "HEAD"]);
    git(repo, ["update-index", "--add", "--cacheinfo", `160000,${commitObject},windows/submodule`]);
    void object;
  });
  assertRejects(() => resolve(windowsHelper, { repository: "owner/repo", platform: "Windows-x64", cacheRoot }, submodule), /submodule/u);

  const collision = createMaliciousRepo(parent, "collision", (repo) => {
    const upper = git(repo, ["hash-object", "-w", "--stdin"], "a\n");
    const lower = git(repo, ["hash-object", "-w", "--stdin"], "b\n");
    git(repo, ["update-index", "--add", "--cacheinfo", `100644,${upper},windows/Readme`]);
    git(repo, ["update-index", "--add", "--cacheinfo", `100644,${lower},windows/readme`]);
  });
  assertRejects(() => resolve(windowsHelper, { repository: "owner/repo", platform: "Windows-x64", cacheRoot }, collision), /case-colliding/u);
}

const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "chatgpt-remote-git-release-selftest-"));
try {
  const cacheRoot = path.join(temporaryRoot, "cache");
  const repo = createGoodRepo(temporaryRoot);
  const windowsOptions = { repository: "owner/repo", platform: "Windows-x64", cacheRoot };
  const originalSpawnSync = childProcess.spawnSync;
  let gitLaunches = 0;
  childProcess.spawnSync = function countedGitLaunch(...args) {
    if (args[0] === "git") gitLaunches += 1;
    return originalSpawnSync(...args);
  };
  let firstWindows;
  try {
    firstWindows = resolve(windowsHelper, windowsOptions, repo);
  } finally {
    childProcess.spawnSync = originalSpawnSync;
  }
  assert.ok(gitLaunches <= 8, `materialization must use one bounded Git batch (got ${gitLaunches} Git launches)`);
  const secondWindows = resolve(windowsHelper, windowsOptions, repo);
  assert.deepEqual(secondWindows, firstWindows, "repeated Git release generation must be deterministic");
  assert.equal(fs.readFileSync(firstWindows.archivePath).equals(fs.readFileSync(secondWindows.archivePath)), true);
  assert.equal(firstWindows.tag, "v1.2.0", "prerelease tags must not win latest stable selection");
  assert.equal(firstWindows.method, "verified-git");
  assert.match(firstWindows.commit, /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/u);
  assert.equal(fs.readdirSync(cacheRoot).some((name) => name.startsWith(".git-release-")), false, "scratch paths must be removed");
  const windowsEntries = readZip(firstWindows.archivePath);
  const windowsRoot = "ChatGPT-Remote-Enabler-Windows-x64-v1.2.0/";
  assert.ok(windowsEntries.every((entry) => entry.name.startsWith(windowsRoot)));
  const sourceEntry = windowsEntries.find((entry) => entry.name === `${windowsRoot}.chatgpt-remote-git-source.json`);
  assert.ok(sourceEntry);
  assert.deepEqual(JSON.parse(sourceEntry.data.toString("utf8")), {
    schemaVersion: 1, repository: "owner/repo", tag: "v1.2.0", commit: firstWindows.commit, platform: "Windows-x64",
  });
  const manifestEntry = windowsEntries.find((entry) => entry.name === `${windowsRoot}RELEASE-MANIFEST.sha256`);
  assert.ok(manifestEntry.data.toString("utf8").includes(` *${sourceEntry.name.slice(windowsRoot.length)}`), "manifest must include source metadata hash");
  assertRejects(() => resolve(windowsHelper, { ...windowsOptions, expectedSha256: "0".repeat(64) }, repo), /does not match generated archive/u);
  const pinned = resolve(windowsHelper, { ...windowsOptions, tag: "v1.0.0" }, repo);
  assert.equal(pinned.tag, "v1.0.0");
  assertRejects(() => resolve(windowsHelper, { ...windowsOptions, tag: "v4.0.0" }, repo), /not advertised/u);

  const macOptions = { repository: "owner/repo", platform: "macOS-arm64", cacheRoot };
  const mac = resolve(macosHelper, macOptions, repo);
  const macEntries = readZip(mac.archivePath);
  const macScript = macEntries.find((entry) => entry.name.endsWith("/Update-ChatGPTRemote.sh"));
  assert.ok(macScript);
  assert.equal(macScript.madeBy >>> 8, 3, "macOS ZIP must identify Unix creator");
  assert.equal((macScript.externalAttributes >>> 16) & 0xffff, 0o100755, "macOS scripts must retain executable mode");
  assert.equal(mac.archiveSha256, crypto.createHash("sha256").update(fs.readFileSync(mac.archivePath)).digest("hex"));

  testMaliciousTrees(temporaryRoot, cacheRoot);
  process.stdout.write(`${JSON.stringify({ ok: true, deterministic: true, stableTag: firstWindows.tag, pinnedTag: pinned.tag, unixModes: true, maliciousTreesRejected: true, gitLaunchesForMaterialization: gitLaunches })}\n`);
} finally {
  fs.rmSync(temporaryRoot, { recursive: true, force: true });
}
