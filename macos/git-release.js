"use strict";

// Git-only release transport.  Keep this file byte-identical to macos/git-release.js.
// The updater deliberately receives a local archive produced from Git objects;
// it never talks to a release API and never downloads an archive from HTTP.

const crypto = require("node:crypto");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const MAX_COMMAND_OUTPUT = 16 * 1024 * 1024;
const MAX_BLOB_OUTPUT = 512 * 1024 * 1024;
const MAX_BATCH_INPUT = 4 * 1024 * 1024;
const MAX_BATCH_OUTPUT = MAX_BLOB_OUTPUT + MAX_COMMAND_OUTPUT;
const COMMAND_TIMEOUT_MS = 45_000;
const TOTAL_TIMEOUT_MS = 175_000;
const SOURCE_METADATA = ".chatgpt-remote-git-source.json";
const RELEASE_MANIFEST = "RELEASE-MANIFEST.sha256";
const ARCHIVE_DIRECTORY = "archives";
const SOURCE_SCHEMA_VERSION = 1;

const PLATFORM_DIRECTORIES = Object.freeze({
  "Windows-x64": "windows",
  "macOS-arm64": "macos",
});

function own(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key);
}

function isWithin(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative !== "" && relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function pathKey(value) {
  return process.platform === "win32" ? value.toLowerCase() : value;
}

function safeRelative(value) {
  if (typeof value !== "string" || value.length === 0 || value.includes("\0") || value.includes("\\") ||
      value.startsWith("/") || path.win32.isAbsolute(value) || value.includes(":") ||
      /[\u0000-\u001f\u007f]/u.test(value)) {
    throw new Error(`Unsafe Git path: ${String(value)}`);
  }
  const pieces = value.split("/");
  if (pieces.some((piece) => piece.length === 0 || piece === "." || piece === ".." || piece.endsWith(" ") || piece.endsWith("."))) {
    throw new Error(`Unsafe Git path: ${value}`);
  }
  const normalized = path.posix.normalize(value);
  if (normalized !== value || normalized === "." || normalized.startsWith("../") || path.posix.isAbsolute(normalized)) {
    throw new Error(`Unsafe Git path: ${value}`);
  }
  return value;
}

function validateRepository(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*$/u.test(value)) {
    throw new Error("Repository must use a validated owner/name form.");
  }
  const [owner, repository] = value.split("/");
  if (owner === "." || owner === ".." || repository === "." || repository === "..") {
    throw new Error("Repository owner and name are invalid.");
  }
  return value;
}

function validatePlatform(value) {
  if (!own(PLATFORM_DIRECTORIES, value)) throw new Error(`Unsupported release platform: ${value}`);
  return value;
}

function validateHash(value) {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/iu.test(value)) {
    throw new Error("Expected archive SHA-256 must contain 64 hexadecimal characters.");
  }
  return value.toLowerCase();
}

function parseVersion(value, { allowPrerelease = true } = {}) {
  if (typeof value !== "string") throw new Error(`Invalid release tag: ${String(value)}`);
  const match = /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/u.exec(value);
  if (!match || (!allowPrerelease && match[4])) throw new Error(`Invalid release tag: ${value}`);
  if (match[4]?.split(".").some((identifier) => /^0[0-9]+$/u.test(identifier))) throw new Error(`Invalid release tag: ${value}`);
  return {
    value,
    major: BigInt(match[1]),
    minor: BigInt(match[2]),
    patch: BigInt(match[3]),
    prerelease: match[4] || null,
    build: match[5] || null,
  };
}

function compareVersions(left, right) {
  for (const component of ["major", "minor", "patch"]) {
    if (left[component] !== right[component]) return left[component] > right[component] ? 1 : -1;
  }
  if (left.prerelease === null && right.prerelease !== null) return 1;
  if (left.prerelease !== null && right.prerelease === null) return -1;
  if (left.prerelease !== right.prerelease) {
    const a = left.prerelease ? left.prerelease.split(".") : [];
    const b = right.prerelease ? right.prerelease.split(".") : [];
    for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
      if (index >= a.length) return -1;
      if (index >= b.length) return 1;
      if (a[index] === b[index]) continue;
      const aNumeric = /^(0|[1-9][0-9]*)$/u.test(a[index]);
      const bNumeric = /^(0|[1-9][0-9]*)$/u.test(b[index]);
      if (aNumeric && bNumeric) return BigInt(a[index]) > BigInt(b[index]) ? 1 : -1;
      if (aNumeric !== bNumeric) return aNumeric ? -1 : 1;
      return a[index] > b[index] ? 1 : -1;
    }
  }
  return left.value < right.value ? -1 : left.value > right.value ? 1 : 0;
}

function githubRemote(repository) {
  const [owner, name] = validateRepository(repository).split("/");
  return `https://github.com/${owner}/${name}.git`;
}

function assertSafeDirectoryPath(value, label, { create = true } = {}) {
  if (typeof value !== "string" || value.trim() === "") throw new Error(`${label} is required.`);
  const resolved = path.resolve(value);
  if (resolved === path.parse(resolved).root) throw new Error(`${label} cannot be a filesystem root.`);
  let current = path.parse(resolved).root;
  const relative = path.relative(current, resolved);
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    if (!fs.existsSync(current)) continue;
    const details = fs.lstatSync(current);
    if (details.isSymbolicLink() || !details.isDirectory()) throw new Error(`${label} traverses a non-directory or symbolic link: ${resolved}`);
  }
  if (create) fs.mkdirSync(resolved, { recursive: true });
  const details = fs.lstatSync(resolved);
  if (!details.isDirectory() || details.isSymbolicLink()) throw new Error(`${label} must be a real directory: ${resolved}`);
  return resolved;
}

function assertSafeTestRemote(value) {
  if (typeof value !== "string" || value.trim() === "") throw new Error("Test remote path is required.");
  const resolved = path.resolve(value);
  if (resolved === path.parse(resolved).root) throw new Error("Test remote path cannot be a filesystem root.");
  const details = fs.lstatSync(resolved);
  if (!details.isDirectory() || details.isSymbolicLink()) throw new Error("Test remote path must be a real Git directory.");
  return resolved;
}

function makeContext() {
  return { deadline: Date.now() + TOTAL_TIMEOUT_MS };
}

function commandEnvironment() {
  return {
    ...process.env,
    GIT_TERMINAL_PROMPT: "0",
    GCM_INTERACTIVE: "Never",
    GIT_OPTIONAL_LOCKS: "0",
    GIT_ASKPASS: process.platform === "win32" ? "" : "/usr/bin/false",
  };
}

function gitCandidates() {
  const candidates = ["git", process.env.CHATGPT_REMOTE_GIT, process.env.BUNDLED_CODEX_GIT];
  if (process.platform === "win32") {
    const programFiles = process.env.ProgramW6432 || process.env.ProgramFiles;
    const localAppData = process.env.LOCALAPPDATA;
    if (programFiles) candidates.push(path.join(programFiles, "Git", "cmd", "git.exe"));
    if (localAppData) candidates.push(path.join(localAppData, "Programs", "Git", "cmd", "git.exe"));
    if (process.env.USERPROFILE) candidates.push(path.join(process.env.USERPROFILE, ".cache", "codex-runtimes", "codex-primary-runtime", "dependencies", "native", "git", "cmd", "git.exe"));
  } else {
    candidates.push("/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git");
  }
  return [...new Set(candidates.filter((candidate) => typeof candidate === "string" && candidate.length > 0))];
}

function runGit(context, args, cwd, { maxBuffer = MAX_COMMAND_OUTPUT, input } = {}) {
  const remaining = context.deadline - Date.now();
  if (remaining <= 0) throw new Error("Git release operation exceeded its total timeout.");
  let result;
  for (const executable of [context.gitExecutable, ...gitCandidates()].filter((candidate, index, all) => candidate && all.indexOf(candidate) === index)) {
    const safeArgs = ["-c", `core.hooksPath=${path.join(cwd, ".disabled-hooks")}`, ...args];
    result = childProcess.spawnSync(executable, safeArgs, {
      cwd,
      env: commandEnvironment(),
      encoding: null,
      timeout: Math.min(COMMAND_TIMEOUT_MS, remaining),
      maxBuffer,
      windowsHide: true,
      stdio: [input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
      ...(input === undefined ? {} : { input }),
    });
    if (result.error?.code === "ENOENT") continue;
    context.gitExecutable = executable;
    break;
  }
  if (!result || result.error?.code === "ENOENT") throw new Error("Git executable was not found in PATH or supported installation locations.");
  if (result.error) {
    const suffix = result.error.code === "ETIMEDOUT" ? " (timed out)" : `: ${result.error.message}`;
    throw new Error(`Git command failed${suffix}`);
  }
  if (result.status !== 0) {
    const stderr = Buffer.isBuffer(result.stderr) ? result.stderr.toString("utf8").trim() : String(result.stderr || "").trim();
    throw new Error(`Git command failed with exit ${result.status}${stderr ? `: ${stderr.slice(0, 2000)}` : ""}`);
  }
  return Buffer.isBuffer(result.stdout) ? result.stdout : Buffer.from(result.stdout || "");
}

function parseAdvertisement(stdout) {
  const byTag = new Map();
  for (const line of stdout.toString("utf8").split(/\r?\n/u)) {
    if (!line) continue;
    const separator = line.indexOf("\t");
    if (separator <= 0) throw new Error("Git tag advertisement is malformed.");
    const object = line.slice(0, separator).toLowerCase();
    const ref = line.slice(separator + 1);
    let tag;
    if (ref.endsWith("^{}")) {
      tag = ref.slice("refs/tags/".length, -3);
      if (!ref.startsWith("refs/tags/") || !tag) throw new Error("Git peeled tag advertisement is malformed.");
    } else {
      if (!ref.startsWith("refs/tags/") || ref.includes("^")) throw new Error("Git tag advertisement contains an unsafe ref.");
      tag = ref.slice("refs/tags/".length);
    }
    let version;
    try { version = parseVersion(tag); }
    catch { continue; }
    if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/u.test(object)) throw new Error("Git tag advertisement contains an invalid object ID.");
    const previous = byTag.get(tag) || { tag, version, advertised: null, peeled: null };
    if (ref.endsWith("^{}")) {
      if (previous.peeled && previous.peeled !== object) throw new Error(`Git advertised tag is inconsistent: ${tag}`);
      previous.peeled = object;
    } else {
      if (previous.advertised && previous.advertised !== object) throw new Error(`Git advertised tag is inconsistent: ${tag}`);
      previous.advertised = object;
    }
    byTag.set(tag, previous);
  }
  const tags = [...byTag.values()].filter((entry) => entry.advertised || entry.peeled);
  for (const entry of tags) entry.commit = entry.peeled || entry.advertised;
  return tags;
}

function chooseTag(entries, requestedTag) {
  if (requestedTag !== undefined) {
    const requested = parseVersion(requestedTag);
    const exact = entries.find((entry) => entry.tag === requested.value);
    if (!exact) throw new Error(`Requested release tag was not advertised: ${requested.value}`);
    return exact;
  }
  const stable = entries.filter((entry) => entry.version.prerelease === null);
  if (stable.length === 0) throw new Error("No stable semantic release tag was advertised.");
  stable.sort((left, right) => compareVersions(right.version, left.version) || (left.tag < right.tag ? -1 : left.tag > right.tag ? 1 : 0));
  return stable[0];
}

function parseTree(stdout, platformDirectory) {
  const prefix = `${platformDirectory}/`;
  const records = stdout.toString("utf8").split("\0").filter(Boolean);
  const entries = [];
  const seen = new Set();
  for (const record of records) {
    const separator = record.indexOf("\t");
    if (separator <= 0) throw new Error("Git platform tree is malformed.");
    const header = record.slice(0, separator).split(" ");
    const fullPath = record.slice(separator + 1);
    if (header.length !== 3 || !prefix || !fullPath.startsWith(prefix)) throw new Error("Git platform tree contains an unsafe path.");
    const [mode, type, object] = header;
    const relative = safeRelative(fullPath.slice(prefix.length));
    if (type !== "blob" || !/^100(?:644|755)$/u.test(mode)) {
      throw new Error(`Release platform contains a symbolic link, submodule, or unsupported entry: ${fullPath}`);
    }
    if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/u.test(object)) throw new Error(`Release platform contains an invalid Git object: ${relative}`);
    const key = relative.normalize("NFC").toLowerCase();
    if (seen.has(key)) throw new Error(`Release platform contains case-colliding paths: ${relative}`);
    seen.add(key);
    if (key === SOURCE_METADATA.toLowerCase() || key === RELEASE_MANIFEST.toLowerCase()) {
      throw new Error(`Release platform contains a reserved generated file: ${relative}`);
    }
    entries.push({ relative, object, mode: mode === "100755" ? 0o755 : 0o644 });
  }
  if (entries.length === 0) throw new Error(`Git release contains no tracked ${platformDirectory} files.`);
  entries.sort((left, right) => left.relative < right.relative ? -1 : left.relative > right.relative ? 1 : 0);
  return entries;
}

function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
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

function materializeEntries(context, entries, repository, tag, commit, platform, bareRoot, stageRoot) {
  const versionEntry = entries.find((entry) => entry.relative === "VERSION");
  if (!versionEntry) throw new Error("Release platform is missing its root VERSION file.");
  const objectIds = [...new Set(entries.map((entry) => entry.object))];
  const batchInput = Buffer.from(`${objectIds.map((object) => `${object}\n`).join("")}`, "ascii");
  if (batchInput.length > MAX_BATCH_INPUT) throw new Error("Release platform has too many Git objects for the bounded batch request.");
  const batchOutput = runGit(context, ["-C", bareRoot, "cat-file", "--batch"], stageRoot, {
    maxBuffer: MAX_BATCH_OUTPUT,
    input: batchInput,
  });
  const objectData = new Map();
  let batchOffset = 0;
  for (const object of objectIds) {
    const headerEnd = batchOutput.indexOf(0x0a, batchOffset);
    if (headerEnd < 0) throw new Error("Git cat-file batch response is truncated.");
    const header = batchOutput.subarray(batchOffset, headerEnd).toString("ascii").split(" ");
    if (header.length !== 3 || header[0].toLowerCase() !== object || header[1] !== "blob" ||
        !/^(?:0|[1-9][0-9]*)$/u.test(header[2])) {
      throw new Error(`Git cat-file batch returned an unexpected object header: ${header.join(" ")}`);
    }
    const size = Number(header[2]);
    if (!Number.isSafeInteger(size) || size > MAX_BLOB_OUTPUT) throw new Error("Git cat-file batch object exceeds the bounded blob size.");
    const dataStart = headerEnd + 1;
    const dataEnd = dataStart + size;
    if (dataEnd >= batchOutput.length || batchOutput[dataEnd] !== 0x0a) throw new Error("Git cat-file batch object length or separator is invalid.");
    objectData.set(object, batchOutput.subarray(dataStart, dataEnd));
    batchOffset = dataEnd + 1;
  }
  if (batchOffset !== batchOutput.length) throw new Error("Git cat-file batch response contains trailing data.");
  const materialized = [];
  for (const entry of entries) {
    const data = objectData.get(entry.object);
    if (!data) throw new Error(`Git cat-file batch did not return ${entry.object}.`);
    const destination = path.resolve(stageRoot, ...entry.relative.split("/"));
    if (!isWithin(stageRoot, destination)) throw new Error(`Release path escapes its root: ${entry.relative}`);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.writeFileSync(destination, data, { flag: "wx", mode: entry.mode });
    try { fs.chmodSync(destination, entry.mode); } catch {}
    materialized.push({ ...entry, path: destination, data });
  }
  const actualVersion = materialized.find((entry) => entry.relative === "VERSION").data.toString("utf8").trim();
  if (actualVersion !== tag) throw new Error(`Release VERSION ${actualVersion} does not match tag ${tag}.`);
  const sourceMetadata = {
    schemaVersion: SOURCE_SCHEMA_VERSION,
    repository,
    tag,
    commit,
    platform,
  };
  const metadataPath = path.join(stageRoot, SOURCE_METADATA);
  const metadataData = Buffer.from(`${JSON.stringify(sourceMetadata, null, 2)}\n`, "utf8");
  fs.writeFileSync(metadataPath, metadataData, { flag: "wx", mode: 0o644 });
  materialized.push({ relative: SOURCE_METADATA, mode: 0o644, path: metadataPath, data: metadataData });
  const manifestLines = materialized
    .slice()
    .sort((left, right) => left.relative < right.relative ? -1 : left.relative > right.relative ? 1 : 0)
    .map((entry) => `${sha256(entry.data)} *${entry.relative}`);
  const manifestData = Buffer.from(`${manifestLines.join("\n")}\n`, "utf8");
  fs.writeFileSync(path.join(stageRoot, RELEASE_MANIFEST), manifestData, { flag: "wx", mode: 0o644 });
  materialized.push({ relative: RELEASE_MANIFEST, mode: 0o644, path: path.join(stageRoot, RELEASE_MANIFEST), data: manifestData });
  return materialized;
}

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let index = 0; index < 256; index += 1) {
    let value = index;
    for (let bit = 0; bit < 8; bit += 1) value = (value & 1) ? (value >>> 1) ^ 0xedb88320 : value >>> 1;
    table[index] = value >>> 0;
  }
  return table;
})();

function crc32(data) {
  let value = 0xffffffff;
  for (const byte of data) value = CRC_TABLE[(value ^ byte) & 0xff] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

function zipEntryMode(entry, platform) {
  if (platform === "macOS-arm64" && /\.(?:sh|command)$/iu.test(entry.relative)) return 0o100755;
  return 0o100000 | (entry.mode & 0o777);
}

function createDeterministicZip(materialized, archiveRoot, platform, destination) {
  const isMac = platform === "macOS-arm64";
  const records = materialized.map((entry) => ({
    ...entry,
    name: `${archiveRoot}/${entry.relative}`,
    data: fs.readFileSync(entry.path),
  })).sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
  const localParts = [];
  const centralParts = [];
  let offset = 0;
  for (const entry of records) {
    const name = Buffer.from(entry.name, "utf8");
    if (name.length > 0xffff || entry.data.length > 0xffffffff || offset > 0xffffffff) throw new Error("Release archive exceeds ZIP32 limits.");
    const crc = crc32(entry.data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x800, 6);
    local.writeUInt16LE(0, 8);
    local.writeUInt16LE(0, 10);
    local.writeUInt16LE(33, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(entry.data.length, 18);
    local.writeUInt32LE(entry.data.length, 22);
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(0, 28);
    localParts.push(local, name, entry.data);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(isMac ? 0x0314 : 0x0014, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x800, 8);
    central.writeUInt16LE(0, 10);
    central.writeUInt16LE(0, 12);
    central.writeUInt16LE(33, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(entry.data.length, 20);
    central.writeUInt32LE(entry.data.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt16LE(0, 30);
    central.writeUInt16LE(0, 32);
    central.writeUInt16LE(0, 34);
    central.writeUInt16LE(0, 36);
    central.writeUInt32LE(isMac ? (zipEntryMode(entry, platform) << 16) >>> 0 : 0, 38);
    central.writeUInt32LE(offset, 42);
    centralParts.push(central, name);
    offset += local.length + name.length + entry.data.length;
  }
  const centralDirectory = Buffer.concat(centralParts);
  const localData = Buffer.concat(localParts);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(records.length, 8);
  end.writeUInt16LE(records.length, 10);
  end.writeUInt32LE(centralDirectory.length, 12);
  end.writeUInt32LE(localData.length, 16);
  end.writeUInt16LE(0, 20);
  fs.writeFileSync(destination, Buffer.concat([localData, centralDirectory, end]), { flag: "wx", mode: 0o600 });
}

function safeRemoveScratch(scratch, cacheRoot) {
  try {
    const resolvedScratch = path.resolve(scratch);
    if (isWithin(cacheRoot, resolvedScratch) && path.basename(resolvedScratch).startsWith(".git-release-")) {
      fs.rmSync(resolvedScratch, { recursive: true, force: true });
    }
  } catch {}
}

function cacheArchive(tempArchive, archiveHash, cacheRoot) {
  const archiveDirectory = path.join(cacheRoot, ARCHIVE_DIRECTORY);
  if (!isWithin(cacheRoot, archiveDirectory)) throw new Error("Archive cache path escapes cache root.");
  fs.mkdirSync(archiveDirectory, { recursive: true });
  const directoryDetails = fs.lstatSync(archiveDirectory);
  if (!directoryDetails.isDirectory() || directoryDetails.isSymbolicLink()) throw new Error("Archive cache directory is unsafe.");
  const destination = path.resolve(archiveDirectory, `${archiveHash}.zip`);
  if (!isWithin(cacheRoot, destination)) throw new Error("Archive cache path escapes cache root.");
  if (fs.existsSync(destination)) {
    const details = fs.lstatSync(destination);
    if (!details.isFile() || details.isSymbolicLink()) throw new Error("Content-addressed archive cache entry is unsafe.");
    if (sha256File(destination) !== archiveHash) throw new Error("Content-addressed archive cache entry failed revalidation.");
    fs.unlinkSync(tempArchive);
    return destination;
  }
  try {
    fs.renameSync(tempArchive, destination);
  } catch (error) {
    if (!fs.existsSync(destination)) throw error;
    const details = fs.lstatSync(destination);
    if (!details.isFile() || details.isSymbolicLink() || sha256File(destination) !== archiveHash) {
      throw new Error("Content-addressed archive cache entry failed revalidation after a concurrent write.");
    }
    try { fs.unlinkSync(tempArchive); } catch {}
  }
  const details = fs.lstatSync(destination);
  if (!details.isFile() || details.isSymbolicLink() || sha256File(destination) !== archiveHash) throw new Error("Cached release archive failed final verification.");
  return destination;
}

function resolveRelease(options, dependencies = {}) {
  const context = makeContext();
  const repository = validateRepository(options?.repository);
  const platform = validatePlatform(options?.platform);
  const cacheRoot = assertSafeDirectoryPath(options?.cacheRoot, "Cache root");
  const requestedTag = options?.tag === undefined ? undefined : parseVersion(options.tag).value;
  const expectedHash = options?.expectedSha256 === undefined ? undefined : validateHash(options.expectedSha256);
  let scratch = null;
  try {
    let remote;
    if (dependencies?.testRemotePath !== undefined) {
      remote = assertSafeTestRemote(dependencies.testRemotePath);
    } else if (dependencies?.remotePath !== undefined) {
      throw new Error("Unconstrained remote path injection is test-only; use testRemotePath in function dependencies.");
    } else {
      remote = githubRemote(repository);
    }
    scratch = fs.mkdtempSync(path.join(cacheRoot, ".git-release-"));
    const advertisement = runGit(context, ["ls-remote", "--tags", remote], scratch);
    const selected = chooseTag(parseAdvertisement(advertisement), requestedTag);
    const bareRoot = path.join(scratch, "objects.git");
    runGit(context, ["init", "--bare", "--quiet", bareRoot], scratch);
    runGit(context, ["-C", bareRoot, "remote", "add", "origin", remote], scratch);
    runGit(context, ["-C", bareRoot, "fetch", "--no-tags", "--depth=1", "origin", `+refs/tags/${selected.tag}:refs/tags/${selected.tag}`], scratch);
    const fetchedCommit = runGit(context, ["-C", bareRoot, "rev-parse", "--verify", `refs/tags/${selected.tag}^{commit}`], scratch).toString("utf8").trim().toLowerCase();
    if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/u.test(fetchedCommit)) throw new Error("Fetched release tag did not resolve to a commit.");
    if (fetchedCommit !== selected.commit) throw new Error(`Release tag moved between advertisement and fetch: ${selected.tag}`);
    const objectType = runGit(context, ["-C", bareRoot, "cat-file", "-t", fetchedCommit], scratch).toString("utf8").trim();
    if (objectType !== "commit") throw new Error("Fetched release object is not a commit.");
    const platformDirectory = PLATFORM_DIRECTORIES[platform];
    const tree = parseTree(runGit(context, ["-C", bareRoot, "ls-tree", "-r", "-z", "--full-tree", fetchedCommit, "--", platformDirectory], scratch), platformDirectory);
    const stageRoot = path.join(scratch, "stage");
    fs.mkdirSync(stageRoot);
    const materialized = materializeEntries(context, tree, repository, selected.tag, fetchedCommit, platform, bareRoot, stageRoot);
    const archiveRoot = `ChatGPT-Remote-Enabler-${platform}-${selected.tag}`;
    const tempArchive = path.join(scratch, `${archiveRoot}.zip`);
    createDeterministicZip(materialized, archiveRoot, platform, tempArchive);
    const archiveHash = sha256File(tempArchive);
    if (expectedHash !== undefined && expectedHash !== archiveHash) throw new Error(`Expected archive SHA-256 ${expectedHash} does not match generated archive ${archiveHash}.`);
    const archivePath = cacheArchive(tempArchive, archiveHash, cacheRoot);
    return { tag: selected.tag, archiveSha256: archiveHash, archivePath, commit: fetchedCommit, method: "verified-git" };
  } finally {
    if (scratch) safeRemoveScratch(scratch, cacheRoot);
  }
}

function parseArguments(argv) {
  if (argv.shift() !== "resolve") throw new Error("Usage: node git-release.js resolve --repository owner/name --platform Windows-x64|macOS-arm64 --cache-root PATH [--tag v1.2.3] [--expected-sha256 HASH]");
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith("--") || value === undefined || own(values, flag.slice(2))) throw new Error(`Invalid argument near ${flag || "end of command"}.`);
    values[flag.slice(2)] = value;
  }
  const allowed = new Set(["repository", "platform", "cache-root", "tag", "expected-sha256"]);
  for (const key of Object.keys(values)) if (!allowed.has(key)) throw new Error(`Unknown argument: --${key}`);
  if (!values.repository || !values.platform || !values["cache-root"]) throw new Error("--repository, --platform, and --cache-root are required.");
  return {
    repository: values.repository,
    platform: values.platform,
    cacheRoot: values["cache-root"],
    ...(values.tag === undefined ? {} : { tag: values.tag }),
    ...(values["expected-sha256"] === undefined ? {} : { expectedSha256: values["expected-sha256"] }),
  };
}

if (require.main === module) {
  try {
    process.stdout.write(`${JSON.stringify(resolveRelease(parseArguments(process.argv.slice(2))))}\n`);
  } catch (error) {
    process.stderr.write(`${error?.message || String(error)}\n`);
    process.exitCode = 1;
  }
}

module.exports = {
  resolveRelease,
  validateRepository,
  validatePlatform,
  parseVersion,
};
