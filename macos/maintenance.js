"use strict";

const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const DAY_MS = 24 * 60 * 60 * 1000;
const LOG_RETENTION_DAYS = 7;
const LOG_CAP_BYTES = 96 * 1024 * 1024;

function appProcessesRunning() {
  if (process.platform === "win32") {
    const result = childProcess.spawnSync("tasklist.exe", ["/FO", "CSV", "/NH"], {
      encoding: "utf8",
      timeout: 15_000,
      windowsHide: true,
    });
    if (result.status !== 0) return { safe: false, reason: "process-check-failed" };
    const names = [...String(result.stdout).matchAll(/^"([^"]+)"/gmu)].map((match) => match[1].toLowerCase());
    const running = [...new Set(names.filter((name) => name === "chatgpt.exe" || name === "codex.exe"))];
    return { safe: running.length === 0, running };
  }
  if (process.platform === "darwin") {
    const running = [];
    for (const name of ["ChatGPT", "Codex", "codex"]) {
      const result = childProcess.spawnSync("/usr/bin/pgrep", ["-x", name], { encoding: "utf8", timeout: 5000 });
      if (result.status === 0 && String(result.stdout).trim()) running.push(name);
      else if (result.status !== 1) return { safe: false, reason: "process-check-failed" };
    }
    return { safe: running.length === 0, running };
  }
  return { safe: false, reason: "unsupported-platform" };
}

function databaseStats(db) {
  const pageCount = Number(db.prepare("PRAGMA page_count").get().page_count ?? 0);
  const freePages = Number(db.prepare("PRAGMA freelist_count").get().freelist_count ?? 0);
  const pageSize = Number(db.prepare("PRAGMA page_size").get().page_size ?? 0);
  return { freeBytes: freePages * pageSize, freePages, pageCount, pageSize };
}

function safeTemporaryTestRoot(codexHome) {
  if (!process.argv.includes("--test-temp")) return false;
  try {
    if (fs.lstatSync(codexHome).isSymbolicLink()) return false;
    const resolvedHome = fs.realpathSync(codexHome);
    const resolvedTemp = fs.realpathSync(os.tmpdir());
    const normalize = (value) => process.platform === "win32" ? value.toLowerCase() : value;
    return normalize(path.dirname(resolvedHome)) === normalize(resolvedTemp)
      && /^chatgpt-remote-maintenance-test-[0-9a-f]{32}$/.test(path.basename(resolvedHome));
  } catch {
    return false;
  }
}

function optimizeDatabase(DatabaseSync, dbPath, pruneLogs) {
  if (!fs.existsSync(dbPath)) return { status: "missing" };
  const beforeBytes = fs.statSync(dbPath).size;
  const db = new DatabaseSync(dbPath);
  let removedByAge = 0;
  let removedByCap = 0;
  try {
    db.exec("PRAGMA busy_timeout=2000");
    if (pruneLogs) {
      const cutoff = Math.floor((Date.now() - LOG_RETENTION_DAYS * DAY_MS) / 1000);
      db.exec("BEGIN IMMEDIATE");
      try {
        const ageResult = db.prepare("DELETE FROM logs WHERE ts < ?").run(cutoff);
        removedByAge = Number(ageResult.changes ?? 0);
        const estimated = Number(db.prepare("SELECT COALESCE(SUM(estimated_bytes), 0) AS bytes FROM logs").get().bytes ?? 0);
        if (!Number.isFinite(estimated) || estimated < 0) throw new Error("Log size estimate is invalid; refusing cap pruning");
        if (estimated > LOG_CAP_BYTES) {
          let accumulated = 0;
          let rows = 0;
          for (const row of db.prepare("SELECT estimated_bytes FROM logs ORDER BY ts, id").iterate()) {
            const rowBytes = Number(row.estimated_bytes ?? 0);
            if (!Number.isFinite(rowBytes) || rowBytes < 0) throw new Error("A log row has an invalid size estimate; refusing cap pruning");
            accumulated += rowBytes;
            rows += 1;
            if (accumulated >= estimated - LOG_CAP_BYTES) break;
          }
          if (rows > 0) {
            const capResult = db.prepare("DELETE FROM logs WHERE id IN (SELECT id FROM logs ORDER BY ts, id LIMIT ?)").run(rows);
            removedByCap = Number(capResult.changes ?? 0);
          }
        }
        db.exec("COMMIT");
      } catch (error) {
        try { db.exec("ROLLBACK"); } catch {}
        throw error;
      }
    }
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    const before = databaseStats(db);
    const shouldVacuum = before.freeBytes >= 8 * 1024 * 1024
      || (before.pageCount > 0 && before.freePages / before.pageCount >= 0.02);
    if (shouldVacuum) db.exec("VACUUM");
    db.exec("PRAGMA optimize");
    const after = databaseStats(db);
    return {
      fileBytesAfter: fs.statSync(dbPath).size,
      fileBytesBefore: beforeBytes,
      freeBytesAfter: after.freeBytes,
      freeBytesBefore: before.freeBytes,
      removedByAge,
      removedByCap,
      status: "optimized",
      vacuumed: shouldVacuum,
    };
  } finally {
    db.close();
  }
}

function main() {
  const codexHomeIndex = process.argv.indexOf("--codex-home");
  const codexHomeArgument = codexHomeIndex >= 0 ? process.argv[codexHomeIndex + 1] : null;
  const codexHome = path.resolve(codexHomeArgument || process.env.CODEX_HOME || path.join(os.homedir(), ".codex"));
  const safeTestOverride = safeTemporaryTestRoot(codexHome);
  const processState = safeTestOverride ? { safe: true, testOverride: true } : appProcessesRunning();
  if (!processState.safe) {
    process.stdout.write(`${JSON.stringify({ processState, status: "skipped-app-running-or-process-check-failed" })}\n`);
    return;
  }
  let DatabaseSync;
  try {
    ({ DatabaseSync } = require("node:sqlite"));
  } catch {
    process.stdout.write(`${JSON.stringify({ processState, status: "skipped-node-sqlite-unavailable" })}\n`);
    return;
  }
  const report = {
    logs: optimizeDatabase(DatabaseSync, path.join(codexHome, "logs_2.sqlite"), true),
    processState,
    state: optimizeDatabase(DatabaseSync, path.join(codexHome, "state_5.sqlite"), false),
    status: "completed",
  };
  process.stdout.write(`${JSON.stringify(report)}\n`);
}

try {
  main();
} catch (error) {
  process.stdout.write(`${JSON.stringify({ error: String(error?.message ?? error).slice(0, 240), status: "skipped-error" })}\n`);
  process.exitCode = 0;
}
