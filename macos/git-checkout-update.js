"use strict";

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { execFileSync } = require("node:child_process");

const CHECKPOINT = ".chatgpt-remote-git-checkpoint.json";
const SOURCE = ".chatgpt-remote-git-source.json";
const oid = value => typeof value === "string" && /^[a-f0-9]{40,64}$/u.test(value);
const samePath = (a, b) => process.platform === "win32" ? path.resolve(a).toLowerCase() === path.resolve(b).toLowerCase() : path.resolve(a) === path.resolve(b);

function realDirectory(directory) {
  const full = path.resolve(directory);
  const details = fs.lstatSync(full);
  if (!details.isDirectory() || details.isSymbolicLink() || !samePath(fs.realpathSync(full), full)) throw new Error("Git update directory must be a real directory without links.");
  return full;
}

function readJson(file) {
  const details = fs.lstatSync(file);
  if (!details.isFile() || details.isSymbolicLink() || details.size > 65536) throw new Error("Invalid Git update metadata file.");
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function atomicJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  realDirectory(path.dirname(file));
  if (fs.existsSync(file) && (!fs.lstatSync(file).isFile() || fs.lstatSync(file).isSymbolicLink())) throw new Error("Git update checkpoint must be a regular file.");
  const scratch = `${file}.tmp-${process.pid}-${crypto.randomBytes(8).toString("hex")}`;
  const descriptor = fs.openSync(scratch, "wx", 0o600);
  try { fs.writeFileSync(descriptor, JSON.stringify(value) + "\n"); fs.fsyncSync(descriptor); }
  finally { fs.closeSync(descriptor); }
  try { fs.renameSync(scratch, file); }
  finally { try { fs.unlinkSync(scratch); } catch {} }
}

function originMatches(actual, repository, expectedOrigin) {
  if (expectedOrigin !== undefined) return actual === expectedOrigin;
  const normalized = actual.replace(/\/$/u, "").replace(/\.git$/u, "");
  return normalized === `https://github.com/${repository}` || normalized === `git@github.com:${repository}`;
}

function context(values, dependencies) {
  const installRoot = realDirectory(values.installRoot);
  const checkoutRoot = realDirectory(path.dirname(installRoot));
  const platformDirectory = values.platform === "Windows-x64" ? "windows" : values.platform === "macOS-arm64" ? "macos" : null;
  if (!platformDirectory || !samePath(path.join(checkoutRoot, platformDirectory), installRoot)) throw new Error("Not a recognized platform source checkout.");
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u.test(values.repository || "")) throw new Error("Invalid Git update repository.");
  const git = values.git || "git";
  const run = (args, allowed = [0]) => {
    try {
      return execFileSync(git, ["-C", checkoutRoot, ...args], {
        encoding: "utf8", timeout: 45000, maxBuffer: 4 * 1024 * 1024, windowsHide: true,
        env: { ...process.env, GIT_TERMINAL_PROMPT: "0", GCM_INTERACTIVE: "never", GIT_ASKPASS: "", SSH_ASKPASS: "" },
        stdio: ["ignore", "pipe", "pipe"],
      }).trim();
    } catch (error) {
      if (allowed.includes(error.status)) return null;
      throw new Error(`Git update command ${args[0]} failed${error.code === "ETIMEDOUT" ? " within its deadline" : ""}; the checkout was not reset.`);
    }
  };
  if (!samePath(run(["rev-parse", "--show-toplevel"]), checkoutRoot)) throw new Error("The source checkout root changed.");
  if (!originMatches(run(["remote", "get-url", "origin"]), values.repository, dependencies.expectedOrigin)) throw new Error("The source checkout origin is not the configured update repository.");
  const version = () => fs.readFileSync(path.join(installRoot, "VERSION"), "utf8").trim();
  const clean = () => {
    if (run(["branch", "--show-current"]) !== "main") throw new Error("The source checkout is not on main; update was skipped.");
    if (run(["status", "--porcelain=v1", "--untracked-files=all"])) throw new Error("The source checkout has local changes; update was skipped without overwriting them.");
    const head = run(["rev-parse", "HEAD"]);
    if (!oid(head)) throw new Error("The source checkout HEAD is invalid.");
    return head;
  };
  return { installRoot, checkoutRoot, run, clean, version };
}

function preparedSource(values, dependencies) {
  const preparedRoot = realDirectory(values.preparedRoot);
  if (!/^v\d+\.\d+\.\d+$/u.test(values.version || "") || !/^[a-f0-9]{64}$/u.test(values.archiveSha256 || "")) throw new Error("Git checkout update needs a pinned release and archive hash.");
  if (dependencies.validatePrepared) dependencies.validatePrepared(values);
  else execFileSync(process.execPath, [path.join(__dirname, "update-transaction.js"), "validate-prepared", "--prepared-root", preparedRoot,
    "--platform", values.platform, "--version", values.version, "--archive-sha256", values.archiveSha256], { windowsHide: true, timeout: 30000, stdio: ["ignore", "pipe", "pipe"] });
  const source = readJson(path.join(preparedRoot, SOURCE));
  if (source.schemaVersion !== 1 || source.repository !== values.repository || source.platform !== values.platform || source.tag !== values.version || !oid(source.commit)) throw new Error("Prepared Git source identity does not match the pinned release.");
  return { preparedRoot, source };
}

function runAction(action, values, dependencies = {}) {
  const ctx = context(values, dependencies);
  const journalPath = path.resolve(values.journalPath);
  const journalRelative = path.relative(ctx.checkoutRoot, journalPath);
  if (!journalRelative || (journalRelative !== ".." && !journalRelative.startsWith(`..${path.sep}`) && !path.isAbsolute(journalRelative))) throw new Error("Git transaction journal must be outside the checkout.");
  if (action === "recover") {
    if (!fs.existsSync(journalPath)) return { recovered: false, integrityValid: true, version: ctx.version(), installKind: "git-checkout" };
    const journal = readJson(journalPath);
    if (journal.schemaVersion !== 1 || !samePath(journal.installRoot, ctx.installRoot) || !samePath(journal.checkoutRoot, ctx.checkoutRoot) ||
        journal.repository !== values.repository || !oid(journal.previousHead) || !oid(journal.target) || !/^v\d+\.\d+\.\d+$/u.test(journal.version || "")) throw new Error("UNSAFE_MIXED_INSTALL: invalid Git update checkpoint.");
    const head = ctx.clean();
    if (head !== journal.target && head !== journal.previousHead) throw new Error("UNSAFE_MIXED_INSTALL: Git HEAD changed during update; automatic recovery will not reset local work.");
    if (head === journal.target && ctx.version() !== journal.version) throw new Error("UNSAFE_MIXED_INSTALL: Git update VERSION does not match its checkpoint.");
    fs.unlinkSync(journalPath);
    return { recovered: true, integrityValid: true, version: ctx.version(), installKind: "git-checkout", recoveryMode: head === journal.target ? "complete-forward" : "unchanged" };
  }
  if (fs.existsSync(journalPath)) throw new Error("UPDATE_RECOVERY_REQUIRED: recover the pending Git update before preparing another release.");
  const { preparedRoot, source } = preparedSource(values, dependencies);
  const before = ctx.clean();
  const checkpointPath = path.join(preparedRoot, CHECKPOINT);
  if (action === "prepare") {
    ctx.run(["fetch", "--quiet", "--no-tags", "origin", `refs/tags/${source.tag}`]);
    const target = ctx.run(["rev-parse", "FETCH_HEAD^{commit}"]);
    if (target !== source.commit) throw new Error("The release tag moved after its content was pinned; check for updates again.");
    if (before !== target && ctx.run(["merge-base", "--is-ancestor", before, target], [0, 1]) === null) throw new Error("The source checkout is ahead of or diverged from this release; update was skipped.");
    if (ctx.clean() !== before) throw new Error("The source checkout changed while the release was prepared.");
    atomicJson(checkpointPath, { schemaVersion: 1, installRoot: ctx.installRoot, checkoutRoot: ctx.checkoutRoot, repository: values.repository,
      previousHead: before, target, version: values.version, archiveSha256: values.archiveSha256 });
    return { prepared: true, preparedPath: preparedRoot, version: values.version, archiveSha256: values.archiveSha256, method: "git-fast-forward" };
  }
  if (action !== "apply") throw new Error("Unsupported source checkout update action.");
  const checkpoint = readJson(checkpointPath);
  if (checkpoint.schemaVersion !== 1 || !samePath(checkpoint.installRoot, ctx.installRoot) || !samePath(checkpoint.checkoutRoot, ctx.checkoutRoot) ||
      checkpoint.repository !== values.repository || checkpoint.target !== source.commit || checkpoint.previousHead !== before ||
      checkpoint.version !== values.version || checkpoint.archiveSha256 !== values.archiveSha256) throw new Error("The source checkout changed after preparation; update was skipped.");
  if (ctx.run(["rev-parse", `${source.commit}^{commit}`]) !== source.commit) throw new Error("The pinned Git commit is unavailable.");
  if (before !== source.commit && ctx.run(["merge-base", "--is-ancestor", before, source.commit], [0, 1]) === null) throw new Error("The pinned release is not a fast-forward.");
  atomicJson(journalPath, checkpoint);
  const hooks = path.join(path.dirname(journalPath), "disabled-update-hooks");
  fs.mkdirSync(hooks, { recursive: true }); realDirectory(hooks);
  ctx.run(["-c", `core.hooksPath=${hooks}`, "-c", "submodule.recurse=false", "merge", "--ff-only", "--quiet", source.commit]);
  if (ctx.clean() !== source.commit || ctx.version() !== values.version) throw new Error("UNSAFE_MIXED_INSTALL: Git did not confirm the exact pinned release.");
  fs.unlinkSync(journalPath);
  return { updated: true, version: values.version, archiveSha256: values.archiveSha256, method: "git-fast-forward" };
}

function main(argv) {
  const action = argv.shift();
  const names = { "install-root": "installRoot", "prepared-root": "preparedRoot", "journal-path": "journalPath", "archive-sha256": "archiveSha256", repository: "repository", platform: "platform", version: "version", git: "git" };
  const values = {};
  while (argv.length) {
    const flag = argv.shift(); const value = argv.shift(); const key = names[flag?.slice(2)];
    if (!flag?.startsWith("--") || !key || !value || values[key]) throw new Error("Invalid Git checkout updater arguments.");
    values[key] = value;
  }
  for (const key of ["installRoot", "journalPath", "repository", "platform"]) if (!values[key]) throw new Error(`Missing ${key}.`);
  process.stdout.write(JSON.stringify(runAction(action, values)) + "\n");
}

module.exports = { runAction };
if (require.main === module) {
  try { main(process.argv.slice(2)); }
  catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 1; }
}
