"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { runAction } = require("../windows/git-checkout-update.js");
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "git-checkout-update-test-"));
const origin = path.join(temporary, "origin");
const git = (cwd, args) => execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8", windowsHide: true, stdio: ["ignore", "pipe", "pipe"] }).trim();
const write = (file, value) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, value); };
let counter = 0;
try {
  fs.mkdirSync(origin);
  git(origin, ["init", "--initial-branch=main"]);
  git(origin, ["config", "user.name", "Fixture"]);
  git(origin, ["config", "user.email", "fixture@example.invalid"]);
  for (const platform of ["windows", "macos"]) { write(path.join(origin, platform, "VERSION"), "v1.0.0\n"); write(path.join(origin, platform, "payload.txt"), "old"); }
  git(origin, ["add", "."]); git(origin, ["commit", "-m", "Old release"]); git(origin, ["tag", "v1.0.0"]);
  const oldHead = git(origin, ["rev-parse", "HEAD"]);
  for (const platform of ["windows", "macos"]) { write(path.join(origin, platform, "VERSION"), "v2.0.0\n"); write(path.join(origin, platform, "payload.txt"), "new"); }
  git(origin, ["add", "."]); git(origin, ["commit", "-m", "New release"]); git(origin, ["tag", "v2.0.0"]);
  const target = git(origin, ["rev-parse", "HEAD"]);
  function fixture(platform = "Windows-x64") {
    const root = path.join(temporary, `checkout-${counter++}`);
    git(temporary, ["clone", "--quiet", origin, root]);
    git(root, ["config", "user.name", "Fixture"]); git(root, ["config", "user.email", "fixture@example.invalid"]);
    // These are isolated disposable fixture branches, never a user checkout.
    git(root, ["reset", "--hard", oldHead]);
    const preparedRoot = path.join(temporary, `prepared-${counter}`);
    const state = path.join(temporary, `state-${counter}`);
    fs.mkdirSync(state);
    write(path.join(preparedRoot, ".chatgpt-remote-git-source.json"), JSON.stringify({ schemaVersion: 1, repository: "fixture/project", tag: "v2.0.0", commit: target, platform }));
    const values = { installRoot: path.join(root, platform === "Windows-x64" ? "windows" : "macos"), preparedRoot, platform,
      journalPath: path.join(state, "git-transaction.json"), repository: "fixture/project", version: "v2.0.0", archiveSha256: "a".repeat(64) };
    let validations = 0;
    const dependencies = { expectedOrigin: origin, validatePrepared: () => { validations += 1; } };
    return { root, values, dependencies, validations: () => validations, checkpoint: () => JSON.parse(fs.readFileSync(path.join(preparedRoot, ".chatgpt-remote-git-checkpoint.json"), "utf8")) };
  }
  for (const platform of ["Windows-x64", "macOS-arm64"]) {
    const f = fixture(platform);
    const prepared = runAction("prepare", f.values, f.dependencies);
    assert.equal(prepared.prepared, true);
    assert.equal(git(f.root, ["rev-parse", "HEAD"]), oldHead, "preparation must leave the source checkout unchanged");
    const result = runAction("apply", f.values, f.dependencies);
    assert.equal(result.method, "git-fast-forward");
    assert.equal(git(f.root, ["rev-parse", "HEAD"]), target);
    assert.equal(git(f.root, ["status", "--porcelain"]), "", "installed source must agree with the Git index and HEAD");
    assert.equal(fs.readFileSync(path.join(f.values.installRoot, "payload.txt"), "utf8"), "new");
    assert.equal(fs.existsSync(f.values.journalPath), false);
    assert.equal(f.validations(), 2, "both preparation and apply must validate the pinned archive");
  }
  {
    const f = fixture(); write(path.join(f.values.installRoot, "payload.txt"), "user edit");
    assert.throws(() => runAction("prepare", f.values, f.dependencies), /local changes/u);
    assert.equal(fs.readFileSync(path.join(f.values.installRoot, "payload.txt"), "utf8"), "user edit");
  }
  {
    const f = fixture(); git(f.root, ["checkout", "-b", "feature/work"]);
    assert.throws(() => runAction("prepare", f.values, f.dependencies), /not on main/u);
  }
  {
    const f = fixture(); runAction("prepare", f.values, f.dependencies);
    git(f.root, ["commit", "--allow-empty", "-m", "Concurrent work"]);
    const concurrent = git(f.root, ["rev-parse", "HEAD"]);
    assert.throws(() => runAction("apply", f.values, f.dependencies), /changed after preparation/u);
    assert.equal(git(f.root, ["rev-parse", "HEAD"]), concurrent);
  }
  {
    const f = fixture(); git(origin, ["tag", "-f", "v2.0.0", oldHead]);
    assert.throws(() => runAction("prepare", f.values, f.dependencies), /tag moved/u);
    git(origin, ["tag", "-f", "v2.0.0", target]);
  }
  for (const committed of [false, true]) {
    const f = fixture(); runAction("prepare", f.values, f.dependencies);
    write(f.values.journalPath, JSON.stringify(f.checkpoint()));
    if (committed) git(f.root, ["merge", "--ff-only", "--quiet", target]);
    const recovered = runAction("recover", f.values, f.dependencies);
    assert.equal(recovered.recoveryMode, committed ? "complete-forward" : "unchanged");
    assert.equal(fs.existsSync(f.values.journalPath), false);
  }
  {
    const f = fixture(); runAction("prepare", f.values, f.dependencies);
    write(f.values.journalPath, JSON.stringify(f.checkpoint()));
    write(path.join(f.values.installRoot, "payload.txt"), "concurrent edit");
    assert.throws(() => runAction("recover", f.values, f.dependencies), /local changes/u);
    assert.equal(fs.existsSync(f.values.journalPath), true, "ambiguous recovery must retain its checkpoint");
    assert.equal(fs.readFileSync(path.join(f.values.installRoot, "payload.txt"), "utf8"), "concurrent edit");
  }
  {
    const f = fixture(); f.values.journalPath = path.join(f.root, "unsafe-journal.json");
    assert.throws(() => runAction("prepare", f.values, f.dependencies), /outside the checkout/u);
  }
  console.log(JSON.stringify({ pinnedTagFastForward: true, bothPlatforms: true, preparedValidationRepeated: true, dirtyAndNonMainPreserved: true,
    changedHeadRejected: true, movedTagRejected: true, interruptedBeforeAndAfterCommitRecovered: true, ambiguousRecoveryPreservesWork: true }));
} finally {
  if (path.dirname(temporary) !== os.tmpdir() || !path.basename(temporary).startsWith("git-checkout-update-test-")) throw new Error("Unsafe fixture cleanup path");
  fs.rmSync(temporary, { recursive: true, force: true });
}
