#!/bin/zsh
set -euo pipefail
zmodload zsh/datetime

action="${1:-}"
action="${action:l}"
config_path="${2:-}"
[[ "$action" == probe || "$action" == close || "$action" == notify ]] || { print -u2 "Usage: $0 {probe|close|notify} <config-path> [message]"; exit 2; }
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

exact_process_running() {
  /bin/kill -0 "$pid_value" 2>/dev/null || return 1
  local actual_start actual_executable actual_bundle
  actual_start="$(/bin/ps -p "$pid_value" -o lstart= 2>/dev/null | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  actual_executable="$(/bin/ps -p "$pid_value" -o comm= 2>/dev/null | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  actual_bundle="$(/usr/bin/defaults read "$app_path/Contents/Info" CFBundleIdentifier 2>/dev/null)"
  [[ "$actual_start" == "$expected_start" && "$actual_executable" == "$expected_executable" && "$actual_bundle" == "$bundle_id" ]]
}

if [[ "$action" == probe ]]; then
  if exact_process_running; then
    print -r -- "{\"running\":true,\"pid\":$pid_value}"
  else
    print -r -- "{\"running\":false,\"pid\":$pid_value}"
  fi
  exit 0
fi

exact_process_running || { print -u2 "The exact ChatGPT process changed before the graceful close request."; exit 1; }
if ! /usr/bin/osascript -l JavaScript - "$pid_value" "$bundle_id" "$expected_executable" <<'JAVASCRIPT' >/dev/null
ObjC.import("AppKit");
function run(argv) {
  const pid = Number(argv[0]);
  const expectedBundle = String(argv[1]);
  const expectedExecutable = String(argv[2]);
  const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(pid);
  if (!app) throw new Error("The exact application process is no longer running.");
  const actualBundle = ObjC.unwrap(app.bundleIdentifier);
  const actualExecutable = ObjC.unwrap(app.executableURL.path);
  if (actualBundle !== expectedBundle || actualExecutable !== expectedExecutable) {
    throw new Error("The exact application identity changed before termination.");
  }
  if (!app.terminate) throw new Error("The exact application refused graceful termination.");
}
JAVASCRIPT
then
  print -u2 "ChatGPT refused the exact-process graceful termination request; the update was aborted."
  exit 1
fi

deadline=$(( EPOCHSECONDS + 30 ))
while exact_process_running; do
  (( EPOCHSECONDS < deadline )) || { print -u2 "ChatGPT did not exit within 30 seconds after the Apple Event; the update was aborted without force-closing it."; exit 1; }
  sleep 0.2
done
print -r -- "{\"closed\":true,\"pid\":$pid_value,\"method\":\"NSRunningApplicationTerminate\"}"
