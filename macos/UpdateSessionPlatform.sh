#!/bin/zsh
set -euo pipefail
zmodload zsh/datetime

action="${1:-}"
action="${action:l}"
config_path="${2:-}"
node_path="${3:-}"
[[ "$action" == probe || "$action" == close || "$action" == notify ]] || { print -u2 "Usage: $0 {probe|close|notify} <config-path> [node-path|message]"; exit 2; }
[[ -n "$config_path" && "$config_path" == /* && -f "$config_path" ]] || { print -u2 "The update-session configuration path is invalid."; exit 2; }

config_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$config_path"
}

pid_value="$(config_value app.pid)"
expected_start="$(config_value app.startToken)"
expected_executable="$(config_value app.executablePath)"
app_path="$(config_value app.appPath)"
bundle_id="$(config_value app.bundleId)"
[[ "$pid_value" == <-> && "$pid_value" -gt 0 && -n "$expected_start" && "$expected_executable" == /* && "$app_path" == /* ]] \
  || { print -u2 "The macOS app identity is incomplete."; exit 2; }
[[ "$bundle_id" != *[^A-Za-z0-9.-]* && -n "$bundle_id" ]] || { print -u2 "The macOS bundle identifier is invalid."; exit 2; }

if [[ "$action" == notify ]]; then
  message="${3:-The update could not be completed. Review the update-session log.}"
  message="${message//$'\r'/ }"
  message="${message//$'\n'/ }"
  /usr/bin/osascript - "$message" <<'APPLESCRIPT' >/dev/null
on run argv
  display notification (item 1 of argv) with title "ChatGPT Remote update"
end run
APPLESCRIPT
  print -r -- '{"notified":true}'
  exit 0
fi

expected_uid="$(/usr/bin/id -u)"
info_plist="$app_path/Contents/Info.plist"
bundle_executable="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$info_plist" 2>/dev/null || true)"
actual_bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info_plist" 2>/dev/null || true)"
[[ -n "$bundle_executable" && "$bundle_executable" != */* && "$actual_bundle_id" == "$bundle_id" &&
   "$app_path/Contents/MacOS/$bundle_executable" == "$expected_executable" ]] \
  || { print -u2 "The macOS application bundle identity is invalid or changed."; exit 2; }

# Return an identity classification instead of collapsing all failures into a
# false probe.  0=SAME, 1=GONE, 2=ERROR, 3=CHANGED. Only SAME authorizes a
# graceful close request; only GONE authorizes the updater to continue.
exact_process_state() {
  local snapshot line_status=0 line actual_start actual_uid
  snapshot="$(/bin/ps -axo pid=,command= 2>/dev/null)" || return 2
  line="$(print -r -- "$snapshot" | /usr/bin/awk -v expected_pid="$pid_value" -v expected="$expected_executable" '
    {
      if ($1 != expected_pid) next
      found = 1
      $1 = ""
      sub(/^[[:space:]]+/, "")
      if ($0 == expected || index($0, expected " ") == 1 || index($0, expected "\t") == 1) {
        print $0
        matched = 1
      }
    }
    END {
      if (!found) exit 10
      if (!matched) exit 11
    }')" || line_status=$?
  if (( line_status == 10 )); then
    /bin/kill -0 "$pid_value" 2>/dev/null && return 2
    return 1
  fi
  (( line_status == 0 )) || return 3
  [[ -n "$line" ]] || return 2
  actual_start="$(/bin/ps -p "$pid_value" -o lstart= 2>/dev/null | /usr/bin/awk '{$1=$1; print}')" || return 2
  actual_uid="$(/bin/ps -p "$pid_value" -o uid= 2>/dev/null | /usr/bin/awk '{$1=$1; print}')" || return 2
  [[ -n "$actual_start" && -n "$actual_uid" ]] || return 2
  [[ "$actual_start" == "$expected_start" && "$actual_uid" == "$expected_uid" ]] || return 3
  return 0
}

if [[ "$action" == probe ]]; then
  state=0
  exact_process_state || state=$?
  case "$state" in
    0) print -r -- "{\"running\":true,\"pid\":$pid_value}" ;;
    1) print -r -- "{\"running\":false,\"pid\":$pid_value}" ;;
    3) print -u2 "The exact ChatGPT process identity changed during probe."; exit 1 ;;
    *) print -u2 "The exact ChatGPT process could not be validated during probe."; exit 2 ;;
  esac
  exit 0
fi

native_renderer_quit() {
  [[ -n "$node_path" && "$node_path" == /* && -x "$node_path" ]] || return 4
  local renderer_port="$(config_value rendererPort 2>/dev/null || true)"
  [[ "$renderer_port" == <-> && "$renderer_port" -ge 1024 && "$renderer_port" -le 65535 ]] || return 4
  local cdp_path="${0:A:h}/runtime/lib/cdp.js"
  [[ -f "$cdp_path" && ! -L "$cdp_path" ]] || return 4
  local output exit_code=0
  output="$(cat <<'JAVASCRIPT' | "$node_path" --no-warnings - "$cdp_path" "$renderer_port" "$pid_value" 2>&1
"use strict";
const cdp = require(process.argv[2]);
const port = Number(process.argv[3]);
const expectedPid = Number(process.argv[4]);
const timeoutMs = 3000;
async function getJson(pathname) {
  const response = await fetch(`http://127.0.0.1:${port}${pathname}`, {
    headers: { Accept: "application/json", Connection: "close" },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) throw new Error(`Debugger discovery returned HTTP ${response.status}`);
  return response.json();
}
(async () => {
  const version = await getJson("/json/version");
  const browser = new cdp.JsonRpcWebSocket(cdp.forceLoopbackWebSocketUrl(version.webSocketDebuggerUrl, port), { timeoutMs });
  await browser.connect();
  try {
    const system = await browser.call("SystemInfo.getProcessInfo", {}, timeoutMs);
    const owners = (system.processInfo || []).filter((entry) => entry.type === "browser");
    if (owners.length !== 1 || owners[0].id !== expectedPid) {
      throw new Error("The debugger listener is not owned by the exact ChatGPT process.");
    }
  } finally {
    browser.close();
  }
  const targets = await cdp.discoverTargets(port, timeoutMs);
  const matches = targets.filter((target) => target.type === "page" && target.url === "app://-/index.html");
  if (matches.length !== 1) throw new Error(`Expected one exact ChatGPT renderer target; found ${matches.length}.`);
  const page = await cdp.connectTarget(matches[0], port, timeoutMs);
  let dispatched = false;
  try {
    const tree = await page.call("Page.getFrameTree", {}, timeoutMs);
    if (tree?.frameTree?.frame?.url !== "app://-/index.html") {
      throw new Error("The debugger target main frame is not the exact ChatGPT renderer.");
    }
    dispatched = true;
    const result = await page.call("Runtime.evaluate", {
      awaitPromise: false,
      expression: `(() => {
        const bridge = globalThis.electronBridge;
        if (top !== globalThis || location.href !== "app://-/index.html" ||
            typeof bridge?.sendMessageFromView !== "function") {
          return { requested: false };
        }
        bridge.sendMessageFromView({ type: "quit-app" });
        return { requested: true };
      })()`,
      generatePreview: false,
      returnByValue: true,
      userGesture: false,
    }, timeoutMs);
    if (result.exceptionDetails || result.result?.value?.requested !== true) {
      throw new Error("The exact ChatGPT renderer did not accept its native quit command.");
    }
    console.log(JSON.stringify({ requested: true }));
  } catch (error) {
    if (dispatched && error?.code === "WEBSOCKET_CLOSED") {
      console.log(JSON.stringify({ requested: true, connectionClosed: true }));
      return;
    }
    throw error;
  } finally {
    page.close();
  }
})().catch((error) => {
  console.error(String(error?.message || error).replace(/[\r\n\0]+/gu, " ").slice(0, 240));
  process.exitCode = 1;
});
JAVASCRIPT
)" || exit_code=$?
  (( exit_code == 0 && "$output" == *'"requested":true'* )) || return 4
  return 0
}

state=0
exact_process_state || state=$?
case "$state" in
  1) print -r -- "{\"closed\":true,\"pid\":$pid_value,\"method\":\"concurrent-graceful-exit\"}"; exit 0 ;;
  0) ;;
  3) print -u2 "The exact ChatGPT process changed before the graceful close request; the update was aborted."; exit 1 ;;
  *) print -u2 "The exact ChatGPT process could not be validated before the graceful close request; the update was aborted."; exit 1 ;;
esac

close_method=""
if native_renderer_quit; then
  close_method="native-renderer-quit"
else
  state=0
  exact_process_state || state=$?
  case "$state" in
    1) print -r -- "{\"closed\":true,\"pid\":$pid_value,\"method\":\"concurrent-graceful-exit\"}"; exit 0 ;;
    0) ;;
    3) print -u2 "The exact ChatGPT process changed before the permission-free close fallback; the update was aborted."; exit 1 ;;
    *) print -u2 "The exact ChatGPT process could not be revalidated before the permission-free close fallback; the update was aborted."; exit 1 ;;
  esac
  if /bin/kill -TERM "$pid_value" 2>/dev/null; then
    close_method="POSIX_SIGTERM"
  else
    kill_status=$?
    state=0
    exact_process_state || state=$?
    if (( state == 1 )); then
      print -r -- "{\"closed\":true,\"pid\":$pid_value,\"method\":\"concurrent-graceful-exit\"}"
      exit 0
    fi
    print -u2 "The exact ChatGPT process rejected the permission-free graceful close request (exit $kill_status); the update was aborted without force-closing it."
    exit 1
  fi
fi

deadline=$(( EPOCHSECONDS + 30 ))
while true; do
  state=0
  exact_process_state || state=$?
  case "$state" in
    1)
      print -r -- "{\"closed\":true,\"pid\":$pid_value,\"method\":\"$close_method\"}"
      exit 0
      ;;
    0)
      (( EPOCHSECONDS < deadline )) || { print -u2 "ChatGPT did not exit within 30 seconds after $close_method; the update was aborted without force-closing it."; exit 1; }
      sleep 0.2
      ;;
    3) print -u2 "The exact ChatGPT process identity changed while waiting for graceful close; the update was aborted."; exit 1 ;;
    *) print -u2 "The exact ChatGPT process could not be revalidated while waiting for graceful close; the update was aborted."; exit 1 ;;
  esac
done
