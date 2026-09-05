"use strict";

const crypto = require("node:crypto");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const PREPARED_METADATA = ".chatgpt-remote-prepared.json";
const PREPARED_ARCHIVE = ".chatgpt-remote-release.zip";
const SCHEMA_VERSION = 1;
const WRITER_LOCK_SCHEMA_VERSION = 1;

function parseArguments(argv) {
  const action = argv.shift();
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!name?.startsWith("--") || value === undefined) throw new Error(`Invalid argument near ${name || "end of command"}.`);
    values.set(name.slice(2), value);
  }
  return { action, values };
}

function required(values, name) {
  const value = values.get(name);
  if (!value) throw new Error(`Missing --${name}.`);
  return value;
}

function validateVersion(value) {
  if (!/^v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/.test(value)) throw new Error(`Invalid release version: ${value}`);
  return value;
}

function validateArchiveHash(value) {
  if (!/^[0-9a-f]{64}$/i.test(value)) throw new Error("Archive SHA-256 must contain 64 hexadecimal characters.");
  return value.toLowerCase();
}

function resolved(value) {
  return path.resolve(value);
}

function pathKey(value) {
  const normalized = path.normalize(value);
  return process.platform === "win32" ? normalized.toLowerCase() : normalized;
}

function isWithin(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative !== "" && relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function pathsOverlap(left, right) {
  return pathKey(left) === pathKey(right) || isWithin(left, right) || isWithin(right, left);
}

function assertSeparatedRoots(installRoot, preparedRoot, backupRoot, journalPath) {
  if (pathsOverlap(installRoot, preparedRoot)) throw new Error("Prepared root must remain separate from the install root.");
  if (pathsOverlap(installRoot, backupRoot) || pathsOverlap(preparedRoot, backupRoot)) {
    throw new Error("Rollback root must remain separate from the install and prepared roots.");
  }
  for (const root of [installRoot, preparedRoot, backupRoot]) {
    if (pathKey(journalPath) === pathKey(root) || isWithin(root, journalPath)) {
      throw new Error("Transaction journal must remain outside the install, prepared, and rollback roots.");
    }
  }
}

function assertRealDirectory(directory, label) {
  const details = fs.lstatSync(directory);
  if (!details.isDirectory() || details.isSymbolicLink()) throw new Error(`${label} must be a real directory: ${directory}`);
}

function safeRelative(value) {
  if (!value || value.includes("\0") || path.posix.isAbsolute(value) || path.win32.isAbsolute(value) || value.includes("\\")) {
    throw new Error(`Unsafe manifest path: ${value}`);
  }
  const components = value.split("/");
  if (components.some((component) => !component || component === "." || component === "..")) throw new Error(`Unsafe manifest path: ${value}`);
  return components.join("/");
}

function assertSafeDestination(root, relative) {
  assertRealDirectory(root, "Install root");
  const destination = path.resolve(root, ...safeRelative(relative).split("/"));
  if (!isWithin(root, destination)) throw new Error(`Install path escapes its root: ${relative}`);
  let current = root;
  for (const component of safeRelative(relative).split("/")) {
    current = path.join(current, component);
    if (!fs.existsSync(current)) continue;
    const details = fs.lstatSync(current);
    if (details.isSymbolicLink()) throw new Error(`Install destination traverses a symbolic link: ${relative}`);
  }
  return destination;
}

function sha256File(file) {
  const hash = crypto.createHash("sha256");
  const descriptor = fs.openSync(file, "r");
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  try {
    for (;;) {
      const count = fs.readSync(descriptor, buffer, 0, buffer.length, null);
      if (count === 0) break;
      hash.update(buffer.subarray(0, count));
    }
  } finally {
    fs.closeSync(descriptor);
  }
  return hash.digest("hex");
}

function syncDirectory(directory) {
  try {
    const descriptor = fs.openSync(directory, "r");
    try { fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
  } catch {
    // Windows does not permit opening every directory for fsync. File fsync and
    // atomic rename still provide the strongest portable boundary available.
  }
}

function syncDirectoriesThrough(directory, root) {
  let current = path.resolve(directory);
  const stop = path.resolve(root);
  for (;;) {
    syncDirectory(current);
    if (pathKey(current) === pathKey(stop)) break;
    if (!isWithin(stop, current)) break;
    current = path.dirname(current);
  }
}

function replaceFile(source, destination) {
  if (process.platform === "win32" && fs.existsSync(destination)) {
    const replacedBackup = `${destination}.replace-old-${process.pid}-${crypto.randomBytes(6).toString("hex")}`;
    const host = process.env.CHATGPT_REMOTE_POWERSHELL_HOST || "powershell.exe";
    const command = "[IO.File]::Replace($env:CHATGPT_REMOTE_REPLACE_SOURCE, $env:CHATGPT_REMOTE_REPLACE_DESTINATION, $env:CHATGPT_REMOTE_REPLACE_BACKUP, $true)";
    const result = childProcess.spawnSync(host, ["-NoProfile", "-NonInteractive", "-Command", command], {
      encoding: "utf8",
      windowsHide: true,
      env: {
        ...process.env,
        CHATGPT_REMOTE_REPLACE_SOURCE: source,
        CHATGPT_REMOTE_REPLACE_DESTINATION: destination,
        CHATGPT_REMOTE_REPLACE_BACKUP: replacedBackup,
      },
    });
    if (result.error || result.status !== 0) {
      throw new Error(`Atomic Windows file replacement failed: ${result.error?.message || result.stderr?.trim() || `exit ${result.status}`}`);
    }
    // File.Replace has already committed the new destination atomically. This
    // only removes its now-unneeded copy of the old destination.
    try { fs.unlinkSync(replacedBackup); } catch {}
  } else {
    fs.renameSync(source, destination);
  }
  syncDirectory(path.dirname(destination));
}

function atomicWriteJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${crypto.randomBytes(8).toString("hex")}`;
  const descriptor = fs.openSync(temporary, "wx", 0o600);
  try {
    fs.writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`, "utf8");
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  replaceFile(temporary, file);
}

function readJson(file, label) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); }
  catch (error) { throw new Error(`${label} is unreadable: ${error.message}`); }
}

function processIsAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (error) {
    if (error?.code === "ESRCH") return false;
    if (error?.code === "EPERM") return true;
    throw new Error(`UNSAFE_MIXED_INSTALL: transaction writer liveness could not be determined (${error?.code || "unknown error"}).`);
  }
}

function writerLockPath(journalPath) {
  return `${journalPath}.writer.lock`;
}

function readWriterLockOwner(lockPath, journalPath) {
  const ownerPath = path.join(lockPath, "owner.json");
  if (!fs.existsSync(ownerPath)) return null;
  const details = fs.lstatSync(ownerPath);
  if (!details.isFile() || details.isSymbolicLink()) throw new Error("UNSAFE_MIXED_INSTALL: transaction writer lock owner is not a regular file.");
  let owner;
  try { owner = readJson(ownerPath, "Transaction writer lock owner"); }
  catch { throw new Error("UNSAFE_MIXED_INSTALL: transaction writer lock owner is malformed."); }
  if (owner.schemaVersion !== WRITER_LOCK_SCHEMA_VERSION || !Number.isSafeInteger(owner.pid) || owner.pid <= 0 ||
      !/^[0-9a-f]{32}$/u.test(owner.token || "") || pathKey(resolved(owner.journalPath || "")) !== pathKey(journalPath)) {
    throw new Error("UNSAFE_MIXED_INSTALL: transaction writer lock owner is malformed.");
  }
  return owner;
}

function tryReclaimWriterLock(lockPath, journalPath) {
  const reclaimPath = `${lockPath}.reclaim`;
  const reclaimToken = crypto.randomBytes(16).toString("hex");
  try {
    fs.mkdirSync(reclaimPath);
    try { atomicWriteJson(path.join(reclaimPath, "owner.json"), { schemaVersion: 1, pid: process.pid, token: reclaimToken }); }
    catch (error) { try { fs.rmSync(reclaimPath, { recursive: true, force: true }); } catch {} throw error; }
  } catch (error) {
    if (error?.code === "EEXIST") throw new Error("UPDATE_BUSY: transaction writer lock is already being reclaimed.");
    throw error;
  }
  try {
    let lockDetails;
    try { lockDetails = fs.lstatSync(lockPath); }
    catch (error) { if (error?.code === "ENOENT") return true; throw error; }
    if (!lockDetails.isDirectory() || lockDetails.isSymbolicLink()) {
      throw new Error("UNSAFE_MIXED_INSTALL: transaction writer lock path is unsafe.");
    }
    const currentOwner = readWriterLockOwner(lockPath, journalPath);
    if (!currentOwner) return false;
    if (processIsAlive(currentOwner.pid)) return false;
    const stalePath = `${lockPath}.stale-${process.pid}-${crypto.randomBytes(8).toString("hex")}`;
    fs.renameSync(lockPath, stalePath);
    fs.rmSync(stalePath, { recursive: true, force: true });
    syncDirectory(path.dirname(lockPath));
    return true;
  } finally {
    try {
      const reclaimOwner = readJson(path.join(reclaimPath, "owner.json"), "Writer reclaim owner");
      if (reclaimOwner.pid === process.pid && reclaimOwner.token === reclaimToken) {
        fs.unlinkSync(path.join(reclaimPath, "owner.json"));
        fs.rmdirSync(reclaimPath);
        syncDirectory(path.dirname(reclaimPath));
      }
    } catch {}
  }
}

function acquireWriterLock(journalPath) {
  const lockPath = writerLockPath(journalPath);
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  for (;;) {
    try {
      fs.mkdirSync(lockPath);
      const lock = { lockPath, journalPath, pid: process.pid, token: crypto.randomBytes(16).toString("hex") };
      try {
        atomicWriteJson(path.join(lockPath, "owner.json"), {
          schemaVersion: WRITER_LOCK_SCHEMA_VERSION,
          pid: lock.pid,
          token: lock.token,
          journalPath,
          acquiredAtUtc: new Date().toISOString(),
        });
        syncDirectory(lockPath);
        return lock;
      } catch (error) {
        try { fs.rmSync(lockPath, { recursive: true, force: true }); } catch {}
        throw error;
      }
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
    }
    let lockDetails;
    try { lockDetails = fs.lstatSync(lockPath); }
    catch (error) { if (error?.code === "ENOENT") continue; throw error; }
    if (!lockDetails.isDirectory() || lockDetails.isSymbolicLink()) {
      throw new Error("UNSAFE_MIXED_INSTALL: transaction writer lock path is unsafe.");
    }
    const owner = readWriterLockOwner(lockPath, journalPath);
    if (owner) {
      if (processIsAlive(owner.pid)) throw new Error(`UPDATE_BUSY: transaction writer process ${owner.pid} is still active.`);
      if (tryReclaimWriterLock(lockPath, journalPath)) continue;
    } else throw new Error("UPDATE_BUSY: transaction writer lock has no verifiable owner.");
    throw new Error("UPDATE_BUSY: transaction writer lock is still active.");
  }
}

function releaseWriterLock(lock) {
  const owner = readWriterLockOwner(lock.lockPath, lock.journalPath);
  if (!owner || owner.pid !== lock.pid || owner.token !== lock.token) {
    throw new Error("UNSAFE_MIXED_INSTALL: transaction writer lock ownership changed unexpectedly.");
  }
  fs.unlinkSync(path.join(lock.lockPath, "owner.json"));
  fs.rmdirSync(lock.lockPath);
  syncDirectory(path.dirname(lock.lockPath));
}

function parseManifest(root, verifyFiles = true) {
  assertRealDirectory(root, "Manifest root");
  const manifestPath = path.join(root, "RELEASE-MANIFEST.sha256");
  const manifestDetails = fs.lstatSync(manifestPath);
  if (!manifestDetails.isFile() || manifestDetails.isSymbolicLink()) throw new Error(`Release manifest is missing or linked: ${manifestPath}`);
  const entries = [];
  const seen = new Set();
  for (const rawLine of fs.readFileSync(manifestPath, "utf8").split(/\r?\n/u)) {
    if (!rawLine) continue;
    const match = /^([0-9a-fA-F]{64}) \*(.+)$/.exec(rawLine);
    if (!match) throw new Error(`Malformed release manifest line: ${rawLine}`);
    const relative = safeRelative(match[2]);
    const key = process.platform === "win32" ? relative.toLowerCase() : relative;
    if (seen.has(key)) throw new Error(`Duplicate release manifest path: ${relative}`);
    seen.add(key);
    const source = path.resolve(root, ...relative.split("/"));
    if (!isWithin(root, source)) throw new Error(`Release path escapes its root: ${relative}`);
    const details = fs.lstatSync(source);
    if (!details.isFile() || details.isSymbolicLink()) throw new Error(`Release file is missing or linked: ${relative}`);
    const realSource = fs.realpathSync(source);
    const realRoot = fs.realpathSync(root);
    if (!isWithin(realRoot, realSource)) throw new Error(`Release file resolves outside its root: ${relative}`);
    const hash = match[1].toLowerCase();
    if (verifyFiles && sha256File(source) !== hash) throw new Error(`Release manifest hash mismatch: ${relative}`);
    entries.push({ relative, hash, source });
  }
  if (entries.length === 0) throw new Error("Release manifest is empty.");
  return { entries, manifestPath, manifestHash: sha256File(manifestPath) };
}

function preparedMetadataPath(preparedRoot) {
  return path.join(preparedRoot, PREPARED_METADATA);
}

function sealPrepared(values) {
  const preparedRoot = resolved(required(values, "prepared-root"));
  const platform = required(values, "platform");
  const version = validateVersion(required(values, "version"));
  const archiveSha256 = validateArchiveHash(required(values, "archive-sha256"));
  const manifest = parseManifest(preparedRoot, true);
  const retainedArchive = path.join(preparedRoot, PREPARED_ARCHIVE);
  const archiveDetails = fs.lstatSync(retainedArchive);
  if (!archiveDetails.isFile() || archiveDetails.isSymbolicLink() || sha256File(retainedArchive) !== archiveSha256) {
    throw new Error("Retained prepared archive does not match the pinned SHA-256.");
  }
  const versionPath = path.join(preparedRoot, "VERSION");
  if (fs.readFileSync(versionPath, "utf8").trim() !== version) throw new Error("Prepared VERSION does not match the pinned release.");
  const metadata = {
    schemaVersion: SCHEMA_VERSION,
    platform,
    version,
    archiveSha256,
    manifestSha256: manifest.manifestHash,
    archiveFile: PREPARED_ARCHIVE,
    files: manifest.entries.length,
    preparedAtUtc: new Date().toISOString(),
  };
  atomicWriteJson(preparedMetadataPath(preparedRoot), metadata);
  return { prepared: true, preparedPath: preparedRoot, version, archiveSha256, files: manifest.entries.length };
}

function validatePrepared(values) {
  const preparedRoot = resolved(required(values, "prepared-root"));
  const expectedPlatform = required(values, "platform");
  const expectedVersion = validateVersion(required(values, "version"));
  const expectedArchiveHash = validateArchiveHash(required(values, "archive-sha256"));
  const metadata = readJson(preparedMetadataPath(preparedRoot), "Prepared update metadata");
  if (metadata.schemaVersion !== SCHEMA_VERSION || metadata.platform !== expectedPlatform || metadata.version !== expectedVersion ||
      metadata.archiveSha256 !== expectedArchiveHash || metadata.archiveFile !== PREPARED_ARCHIVE ||
      !/^[0-9a-f]{64}$/u.test(metadata.manifestSha256 || "")) {
    throw new Error("Prepared update metadata does not match the pinned release.");
  }
  const manifest = parseManifest(preparedRoot, true);
  const retainedArchive = path.join(preparedRoot, PREPARED_ARCHIVE);
  const archiveDetails = fs.lstatSync(retainedArchive);
  if (!archiveDetails.isFile() || archiveDetails.isSymbolicLink() || sha256File(retainedArchive) !== expectedArchiveHash) {
    throw new Error("Retained prepared archive changed after verification.");
  }
  if (manifest.manifestHash !== metadata.manifestSha256 || manifest.entries.length !== metadata.files) {
    throw new Error("Prepared update manifest changed after verification.");
  }
  if (fs.readFileSync(path.join(preparedRoot, "VERSION"), "utf8").trim() !== expectedVersion) {
    throw new Error("Prepared VERSION changed after verification.");
  }
  return { preparedRoot, metadata, manifest };
}

function copyAndVerify(source, destination, expectedHash) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  const temporary = `${destination}.update-tmp-${process.pid}-${crypto.randomBytes(6).toString("hex")}`;
  try {
    fs.copyFileSync(source, temporary);
    const mode = fs.statSync(source).mode & 0o777;
    try { fs.chmodSync(temporary, mode); } catch {}
    const descriptor = fs.openSync(temporary, "r+");
    try { fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
    if (sha256File(temporary) !== expectedHash) throw new Error(`Copied file failed verification: ${destination}`);
    replaceFile(temporary, destination);
    if (sha256File(destination) !== expectedHash) throw new Error(`Installed file failed verification: ${destination}`);
  } finally {
    try { fs.unlinkSync(temporary); } catch {}
  }
}

function durableBackup(source, destination, expectedHash, backupRoot) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination);
  const mode = fs.statSync(source).mode & 0o777;
  try { fs.chmodSync(destination, mode); } catch {}
  const descriptor = fs.openSync(destination, "r+");
  try { fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
  syncDirectoriesThrough(path.dirname(destination), backupRoot);
  if (sha256File(destination) !== expectedHash) throw new Error(`Rollback copy failed verification: ${destination}`);
}

function tryInstalledManifest(installRoot) {
  try { return { valid: true, ...parseManifest(installRoot, true) }; }
  catch (error) { return { valid: false, entries: [], error: error.message }; }
}

function buildJournal(values) {
  const installRoot = resolved(required(values, "install-root"));
  const journalPath = resolved(required(values, "journal-path"));
  const backupRoot = resolved(required(values, "backup-root"));
  const prepared = validatePrepared(values);
  assertRealDirectory(installRoot, "Install root");
  assertSeparatedRoots(installRoot, prepared.preparedRoot, backupRoot, journalPath);
  if (fs.existsSync(backupRoot)) throw new Error(`Rollback directory already exists: ${backupRoot}`);
  fs.mkdirSync(backupRoot, { recursive: true });
  assertRealDirectory(backupRoot, "Rollback root");
  syncDirectory(path.dirname(backupRoot));

  const previous = tryInstalledManifest(installRoot);
  const newKeys = new Set(prepared.manifest.entries.map((entry) => pathKey(entry.relative)));
  const updaterName = process.platform === "win32" ? "Update-ChatGPTRemote.ps1" : "Update-ChatGPTRemote.sh";
  const copyEntries = [...prepared.manifest.entries].sort((left, right) => {
    const leftLast = left.relative === updaterName ? 1 : 0;
    const rightLast = right.relative === updaterName ? 1 : 0;
    return leftLast - rightLast || left.relative.localeCompare(right.relative);
  });
  const operations = copyEntries.map((entry) => ({ kind: "copy", relative: entry.relative, source: entry.source, hash: entry.hash }));
  if (previous.valid) {
    for (const entry of previous.entries) {
      if (!newKeys.has(pathKey(entry.relative))) operations.push({ kind: "remove", relative: entry.relative });
    }
  }
  operations.push({
    kind: "copy",
    relative: "RELEASE-MANIFEST.sha256",
    source: prepared.manifest.manifestPath,
    hash: prepared.manifest.manifestHash,
  });

  for (const operation of operations) {
    operation.destination = assertSafeDestination(installRoot, operation.relative);
    operation.backup = path.resolve(backupRoot, ...operation.relative.split("/"));
    if (!isWithin(backupRoot, operation.backup)) throw new Error(`Rollback path escapes its root: ${operation.relative}`);
    operation.existed = fs.existsSync(operation.destination);
    operation.backupHash = null;
    if (!operation.existed) continue;
    const details = fs.lstatSync(operation.destination);
    if (!details.isFile() || details.isSymbolicLink()) throw new Error(`Install destination is not a regular file: ${operation.relative}`);
    operation.backupHash = sha256File(operation.destination);
    durableBackup(operation.destination, operation.backup, operation.backupHash, backupRoot);
  }

  return {
    schemaVersion: SCHEMA_VERSION,
    status: "prepared",
    installRoot,
    preparedRoot: prepared.preparedRoot,
    platform: prepared.metadata.platform,
    version: prepared.metadata.version,
    archiveSha256: prepared.metadata.archiveSha256,
    backupRoot,
    previousIntegrityValid: previous.valid,
    previousIntegrityError: previous.error || null,
    completedOperations: 0,
    operations,
    createdAtUtc: new Date().toISOString(),
  };
}

function readJournal(journalPath) {
  const journal = readJson(journalPath, "Update transaction journal");
  if (journal.schemaVersion !== SCHEMA_VERSION || !Array.isArray(journal.operations) || !journal.installRoot ||
      !journal.preparedRoot || !journal.backupRoot || !journal.version || !journal.archiveSha256 ||
      typeof journal.previousIntegrityValid !== "boolean" ||
      !Number.isSafeInteger(journal.completedOperations) || journal.completedOperations < 0 ||
      journal.completedOperations > journal.operations.length || !["prepared", "applying"].includes(journal.status)) {
    throw new Error("Update transaction journal has an invalid schema.");
  }
  return journal;
}

function validateJournalStructure(journalPath, journal) {
  const installRoot = resolved(journal.installRoot);
  const preparedRoot = resolved(journal.preparedRoot);
  const backupRoot = resolved(journal.backupRoot);
  const resolvedJournalPath = resolved(journalPath);
  assertSeparatedRoots(installRoot, preparedRoot, backupRoot, resolvedJournalPath);
  assertRealDirectory(installRoot, "Journal install root");
  assertRealDirectory(backupRoot, "Journal rollback root");
  const seen = new Set();
  for (const operation of journal.operations) {
    const relative = safeRelative(operation.relative);
    const key = pathKey(relative);
    if (seen.has(key)) throw new Error(`Duplicate journal operation: ${relative}`);
    seen.add(key);
    const destination = assertSafeDestination(installRoot, relative);
    const backup = path.resolve(backupRoot, ...relative.split("/"));
    if (!isWithin(backupRoot, backup) || pathKey(backup) !== pathKey(resolved(operation.backup)) ||
        pathKey(destination) !== pathKey(resolved(operation.destination))) {
      throw new Error(`Journal path confinement failed: ${relative}`);
    }
    if (operation.kind === "copy") {
      const sourceRelative = relative === "RELEASE-MANIFEST.sha256" ? "RELEASE-MANIFEST.sha256" : relative;
      const expectedSource = path.resolve(preparedRoot, ...sourceRelative.split("/"));
      if (!/^[0-9a-f]{64}$/u.test(operation.hash || "") ||
          !isWithin(preparedRoot, expectedSource) || pathKey(resolved(operation.source)) !== pathKey(expectedSource)) {
        throw new Error(`Journal source path or hash is invalid: ${relative}`);
      }
    } else if (operation.kind !== "remove" || operation.source != null || operation.hash != null) {
      throw new Error(`Invalid journal operation: ${relative}`);
    }
    if (typeof operation.existed !== "boolean") throw new Error(`Journal existence state is invalid: ${relative}`);
    if (operation.existed) {
      if (!/^[0-9a-f]{64}$/u.test(operation.backupHash || "") || !fs.existsSync(backup)) {
        throw new Error(`Journal rollback copy is missing or invalid: ${relative}`);
      }
      const backupDetails = fs.lstatSync(backup);
      if (!backupDetails.isFile() || backupDetails.isSymbolicLink() || sha256File(backup) !== operation.backupHash) {
        throw new Error(`Journal rollback copy is damaged: ${relative}`);
      }
    } else if (operation.backupHash !== null) {
      throw new Error(`Journal rollback state is ambiguous: ${relative}`);
    }
  }
}

function validateJournalPrepared(journal) {
  const prepared = validatePrepared(new Map([
    ["prepared-root", journal.preparedRoot],
    ["platform", journal.platform],
    ["version", journal.version],
    ["archive-sha256", journal.archiveSha256],
  ]));
  const expectedCopies = new Map(prepared.manifest.entries.map((entry) => [pathKey(entry.relative), { hash: entry.hash, source: entry.source }]));
  expectedCopies.set(pathKey("RELEASE-MANIFEST.sha256"), { hash: prepared.manifest.manifestHash, source: prepared.manifest.manifestPath });
  const actualCopies = journal.operations.filter((operation) => operation.kind === "copy");
  if (actualCopies.length !== expectedCopies.size) throw new Error("Journal copy set does not match the prepared manifest.");
  for (const operation of actualCopies) {
    const expected = expectedCopies.get(pathKey(operation.relative));
    if (!expected || operation.hash !== expected.hash || pathKey(resolved(operation.source)) !== pathKey(expected.source)) {
      throw new Error(`Journal source does not match the prepared manifest: ${operation.relative}`);
    }
  }
  if (!journal.previousIntegrityValid && journal.operations.some((operation) => operation.kind === "remove")) {
    throw new Error("A transaction from an invalid prior manifest cannot contain removals.");
  }
  if (journal.previousIntegrityValid) {
    const previous = parseManifest(resolved(journal.backupRoot), true);
    const newKeys = new Set(prepared.manifest.entries.map((entry) => pathKey(entry.relative)));
    const expectedRemovals = new Set(previous.entries.filter((entry) => !newKeys.has(pathKey(entry.relative))).map((entry) => pathKey(entry.relative)));
    const actualRemovals = journal.operations.filter((operation) => operation.kind === "remove").map((operation) => pathKey(operation.relative));
    if (actualRemovals.length !== expectedRemovals.size || actualRemovals.some((relative) => !expectedRemovals.has(relative))) {
      throw new Error("Journal removal set does not match the previous manifest.");
    }
  }
  return prepared;
}

function removeJournal(journalPath) {
  fs.unlinkSync(journalPath);
  syncDirectory(path.dirname(journalPath));
}

function applyJournal(journalPath, journal) {
  validateJournalStructure(journalPath, journal);
  validateJournalPrepared(journal);
  journal.status = "applying";
  atomicWriteJson(journalPath, journal);
  for (let index = 0; index < journal.operations.length; index += 1) {
    const operation = journal.operations[index];
    const destination = assertSafeDestination(journal.installRoot, operation.relative);
    if (pathKey(destination) !== pathKey(operation.destination)) throw new Error(`Journal destination changed: ${operation.relative}`);
    if (operation.kind === "copy") {
      if (sha256File(operation.source) !== operation.hash) throw new Error(`Prepared source changed during installation: ${operation.relative}`);
      copyAndVerify(operation.source, destination, operation.hash);
    } else if (operation.kind === "remove") {
      if (fs.existsSync(destination)) {
        const details = fs.lstatSync(destination);
        if (!details.isFile() || details.isSymbolicLink()) throw new Error(`Refusing to remove a non-file destination: ${operation.relative}`);
        fs.unlinkSync(destination);
        syncDirectory(path.dirname(destination));
      }
    } else {
      throw new Error(`Unknown journal operation: ${operation.kind}`);
    }
    journal.completedOperations = index + 1;
    atomicWriteJson(journalPath, journal);
  }
  parseManifest(journal.installRoot, true);
  if (fs.readFileSync(path.join(journal.installRoot, "VERSION"), "utf8").trim() !== journal.version) {
    throw new Error("Installed VERSION does not match the completed transaction.");
  }
  removeJournal(journalPath);
  return {
    updated: true,
    version: journal.version,
    archiveSha256: journal.archiveSha256,
    rollbackPath: journal.backupRoot,
    files: journal.operations.filter((operation) => operation.kind === "copy" && operation.relative !== "RELEASE-MANIFEST.sha256").length,
  };
}

function rollbackJournal(journalPath, journal) {
  validateJournalStructure(journalPath, journal);
  const lastPossiblyChanged = Math.min(journal.operations.length - 1, journal.completedOperations);
  for (let index = lastPossiblyChanged; index >= 0; index -= 1) {
    const operation = journal.operations[index];
    const destination = assertSafeDestination(journal.installRoot, operation.relative);
    if (operation.existed) {
      if (!operation.backupHash || !fs.existsSync(operation.backup) || sha256File(operation.backup) !== operation.backupHash) {
        throw new Error(`Rollback copy is missing or damaged: ${operation.relative}`);
      }
      copyAndVerify(operation.backup, destination, operation.backupHash);
    } else if (fs.existsSync(destination)) {
      const details = fs.lstatSync(destination);
      if (!details.isFile() || details.isSymbolicLink()) throw new Error(`Rollback destination is not a regular file: ${operation.relative}`);
      fs.unlinkSync(destination);
      syncDirectory(path.dirname(destination));
    }
  }
  if (!journal.previousIntegrityValid) {
    throw new Error(`The previous installation was already invalid (${journal.previousIntegrityError || "reason unavailable"}) and the prepared update could not be resumed.`);
  }
  parseManifest(journal.installRoot, true);
  removeJournal(journalPath);
  return { recovered: true, recoveryMode: "rollback", integrityValid: true, version: fs.readFileSync(path.join(journal.installRoot, "VERSION"), "utf8").trim() };
}

function recover(values) {
  const journalPath = resolved(required(values, "journal-path"));
  const requestedInstallRoot = values.get("install-root") ? resolved(values.get("install-root")) : null;
  if (!fs.existsSync(journalPath)) {
    if (!requestedInstallRoot) return { recovered: false, integrityValid: true };
    parseManifest(requestedInstallRoot, true);
    return { recovered: false, integrityValid: true, version: fs.readFileSync(path.join(requestedInstallRoot, "VERSION"), "utf8").trim() };
  }
  const journal = readJournal(journalPath);
  if (requestedInstallRoot && pathKey(requestedInstallRoot) !== pathKey(journal.installRoot)) {
    throw new Error(`UNSAFE_MIXED_INSTALL: pending transaction belongs to ${journal.installRoot}.`);
  }
  try { validateJournalStructure(journalPath, journal); }
  catch (error) { throw new Error(`UNSAFE_MIXED_INSTALL: transaction journal is unsafe or ambiguous: ${error.message}`); }
  try { validateJournalPrepared(journal); }
  catch (preparedError) {
    try { return rollbackJournal(journalPath, journal); }
    catch (rollbackError) {
      throw new Error(`UNSAFE_MIXED_INSTALL: prepared update is invalid: ${preparedError.message}; rollback failed: ${rollbackError.message}`);
    }
  }
  try {
    const result = applyJournal(journalPath, journal);
    return { ...result, recovered: true, recoveryMode: "complete-forward", integrityValid: true };
  } catch (forwardError) {
    try { return rollbackJournal(journalPath, journal); }
    catch (rollbackError) {
      throw new Error(`UNSAFE_MIXED_INSTALL: forward recovery failed: ${forwardError.message}; rollback failed: ${rollbackError.message}`);
    }
  }
}

function applyPrepared(values) {
  const journalPath = resolved(required(values, "journal-path"));
  const installRoot = resolved(required(values, "install-root"));
  if (fs.existsSync(journalPath)) recover(new Map([["journal-path", journalPath], ["install-root", installRoot]]));
  const journal = buildJournal(values);
  atomicWriteJson(journalPath, journal);
  try { return applyJournal(journalPath, journal); }
  catch (error) { throw new Error(`UNSAFE_MIXED_INSTALL: transaction is recoverable from ${journalPath}: ${error.message}`); }
}

function main() {
  const { action, values } = parseArguments(process.argv.slice(2));
  const writerLock = ["apply", "recover"].includes(action)
    ? acquireWriterLock(resolved(required(values, "journal-path")))
    : null;
  let result;
  try {
    if (action === "seal-prepared") result = sealPrepared(values);
    else if (action === "validate-prepared") {
      const prepared = validatePrepared(values);
      result = { prepared: true, preparedPath: prepared.preparedRoot, version: prepared.metadata.version, archiveSha256: prepared.metadata.archiveSha256, files: prepared.metadata.files };
    } else if (action === "integrity") {
      const installRoot = resolved(required(values, "install-root"));
      const manifest = parseManifest(installRoot, true);
      result = { integrityValid: true, files: manifest.entries.length, version: fs.readFileSync(path.join(installRoot, "VERSION"), "utf8").trim() };
    } else if (action === "apply") result = applyPrepared(values);
    else if (action === "recover") result = recover(values);
    else throw new Error(`Unsupported transaction action: ${action}`);
  } finally {
    if (writerLock) releaseWriterLock(writerLock);
  }
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

try { main(); }
catch (error) {
  process.stderr.write(`${error?.message || String(error)}\n`);
  process.exitCode = 1;
}
