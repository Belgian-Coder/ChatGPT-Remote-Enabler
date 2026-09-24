"use strict";

const http = require("node:http");
const { JsonRpcWebSocket, evaluate, forceLoopbackWebSocketUrl } = require("./lib/cdp.js");

function targetsAt(port, timeoutMs) {
  return new Promise((resolve, reject) => {
    const request = http.get({ host: "127.0.0.1", port, path: "/json/list", agent: false }, response => {
      if (response.statusCode !== 200) { response.resume(); reject(new Error("Inspector discovery failed.")); return; }
      let body = "";
      response.on("data", chunk => {
        body += chunk;
        if (body.length > 65536) request.destroy(new Error("Inspector discovery response is too large."));
      });
      response.on("error", reject);
      response.on("end", () => { try { const result = JSON.parse(body); if (!Array.isArray(result)) throw Error("Invalid targets"); resolve(result); } catch (error) { reject(error); } });
    });
    const timer = setTimeout(() => request.destroy(new Error("Inspector discovery timed out.")), timeoutMs);
    request.on("error", reject);
    request.on("close", () => clearTimeout(timer));
  });
}

async function openExistingInspector({ pid, executablePath, port = 9229, activateIfMissing = true, rendererTimeoutMs = 30000 }, dependencies = {}) {
  if (!Number.isInteger(pid) || pid <= 0 || !Number.isInteger(port) || port < 1024 || port > 65535 || !executablePath) throw Error("Invalid attachment identity or port.");
  if (!Number.isInteger(rendererTimeoutMs) || rendererTimeoutMs < 0 || rendererTimeoutMs > 60000) throw Error("Invalid renderer attachment timeout.");
  const now = dependencies.now ?? Date.now;
  const sleep = dependencies.sleep ?? (milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds)));
  const discover = dependencies.discover ?? targetsAt;
  const activate = dependencies.activate ?? (targetPid => process._debugProcess(targetPid));
  const connect = dependencies.connect ?? (async target => {
    const client = new JsonRpcWebSocket(forceLoopbackWebSocketUrl(target.webSocketDebuggerUrl, port), { timeoutMs: 2000 });
    await client.connect();
    return client;
  });
  const run = dependencies.evaluate ?? evaluate;
  let targets;
  let activated = false;
  let verified = false;
  let client;
  try {
    try { targets = await discover(port, 500); }
    catch (error) {
      // Only connection refusal proves there is no existing service. Do not
      // signal the app when a busy/malformed/slow listener owns this port.
      if (error.code !== "ECONNREFUSED" || !activateIfMissing) throw error;
      activate(pid);
      activated = true;
      const deadline = Date.now() + 5000;
      while (Date.now() < deadline) {
        try { targets = await discover(port, 300); break; }
        catch (retryError) {
          if (retryError.code !== "ECONNREFUSED") throw retryError;
          await new Promise(resolve => setTimeout(resolve, 100));
        }
      }
    }
    const target = targets?.find(item => item?.type === "node" && typeof item.webSocketDebuggerUrl === "string");
    if (!target) throw Error("The running app did not expose a main-process inspector.");
    client = await connect(target);
    const identity = await run(client, "({pid:process.pid,path:process.execPath,type:process.type})", 2000);
    if (identity?.pid !== pid || identity?.type !== "browser" || typeof identity.path !== "string" || identity.path.toLowerCase() !== executablePath.toLowerCase()) {
      throw Error("Inspector identity did not match the running ChatGPT process. No injection was attempted.");
    }
    verified = true;
    const rendererDeadline = now() + (activateIfMissing ? rendererTimeoutMs : 0);
    let capable = false;
    do {
      capable = await run(client, `(() => {
      const electron = process.getBuiltinModule('module').createRequire(process.resourcesPath + '/app.asar/package.json')('electron');
      return electron.webContents.getAllWebContents().some(w => w.getURL() === 'app://-/index.html' && typeof w.debugger?.sendCommand === 'function');
    })()`, activateIfMissing ? Math.max(1, Math.min(2000, rendererDeadline - now())) : 2000);
      if (capable === true || now() >= rendererDeadline) break;
      await sleep(Math.min(250, rendererDeadline - now()));
    } while (now() < rendererDeadline);
    if (capable !== true) throw Error("The running app has no attachable ChatGPT renderer yet. It was left running.");
    return { pid, rendererPort: port, activated, transport: "electron-main-inspector-v1" };
  } catch (error) {
    if (activated && verified && client) {
      try { await run(client, "setTimeout(() => process.getBuiltinModule('inspector').close(), 100); true", 1000); } catch { }
    }
    throw error;
  } finally { client?.close(); }
}

module.exports = { openExistingInspector, targetsAt };
if (require.main === module) {
  const [pid, executablePath, port, mode, timeout] = process.argv.slice(2);
  openExistingInspector({ pid: Number(pid), executablePath, port: Number(port), activateIfMissing: mode !== '--verify-only', rendererTimeoutMs: timeout === undefined ? 30000 : Number(timeout) }).then(
    result => console.log(JSON.stringify(result)),
    error => { console.error(error.message); process.exitCode = 1; },
  );
}
