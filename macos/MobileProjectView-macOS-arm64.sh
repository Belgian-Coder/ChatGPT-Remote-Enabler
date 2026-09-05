#!/bin/zsh
set -euo pipefail
zmodload zsh/datetime

action="${1:-probe}"
action="${action:l}"
script_path="${0:A}"
bundle_root="${script_path:h}"
injector="$bundle_root/inject.js"
maintenance_helper="$bundle_root/maintenance.js"
updater="$bundle_root/Update-ChatGPTRemote.sh"
update_recovered=0
update_session_source="$bundle_root/update-session.js"
update_session_cdp_source="$bundle_root/update-session-cdp.js"
update_session_platform_source="$bundle_root/UpdateSessionPlatform.sh"
update_transaction_source="$bundle_root/update-transaction.js"
cdp_source="$bundle_root/runtime/lib/cdp.js"
label="com.local.codex-mobile-project-view"
launch_agents="$HOME/Library/LaunchAgents"
plist="$launch_agents/$label.plist"
rollback_root="$bundle_root/rollback"
log_root="$HOME/Library/Logs/CodexRemoteFeatures"
stdout_log="$log_root/mobile-project-view.log"
stderr_log="$log_root/mobile-project-view-error.log"
port="${CODEX_REMOTE_DEBUG_PORT:-9229}"
app_name="${CODEX_APP_NAME:-ChatGPT}"
peer_name="${CODEX_REMOTE_PEER_NAME:-}"
startup_delay_seconds="${CODEX_STARTUP_DELAY_SECONDS:-60}"
startup_required_path="${CODEX_STARTUP_REQUIRED_PATH:-}"
mobile_ready_timeout_seconds="${CODEX_MOBILE_READY_TIMEOUT_SECONDS:-45}"
skip_update_check_once="${CODEX_REMOTE_SKIP_UPDATE_CHECK_ONCE:-0}"
launch_guard="$HOME/Library/Application Support/ChatGPTRemoteEnabler/launch.lock"
launch_guard_token="$$-$EPOCHSECONDS-$RANDOM-launch"
launch_guard_owned=0

release_launch_guard() {
  (( launch_guard_owned )) || return 0
  if [[ -f "$launch_guard/owner" && "$(<"$launch_guard/owner")" == "$launch_guard_token" ]]; then
    rm -f -- "$launch_guard/owner"
    rmdir "$launch_guard" 2>/dev/null || true
  fi
  launch_guard_owned=0
}

trap release_launch_guard EXIT INT TERM

acquire_launch_guard() {
  local deadline=$(( EPOCHSECONDS + 120 )) owner owner_pid modified
  mkdir -p "${launch_guard:h}"
  while (( EPOCHSECONDS < deadline )); do
    if mkdir "$launch_guard" 2>/dev/null; then
      print -rn -- "$launch_guard_token" > "$launch_guard/owner"
      launch_guard_owned=1
      return 0
    fi
    if [[ -f "$launch_guard/owner" ]]; then
      owner="$(<"$launch_guard/owner")"
      owner_pid="${owner%%-*}"
      if [[ "$owner_pid" == <-> ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -f -- "$launch_guard/owner"
        rmdir "$launch_guard" 2>/dev/null || true
      fi
    elif [[ -d "$launch_guard" ]]; then
      modified="$(/usr/bin/stat -f %m "$launch_guard" 2>/dev/null || print 0)"
      if (( modified > 0 && EPOCHSECONDS - modified > 1800 )); then rmdir "$launch_guard" 2>/dev/null || true; fi
    fi
    sleep 0.1
  done
  print -u2 "Timed out waiting for another launch or update to release the launch guard."
  return 1
}

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  print -u2 "This launcher is restricted to macOS on Apple Silicon (arm64)."
  exit 2
fi
if [[ "$EUID" -eq 0 ]]; then
  print -u2 "Run this as the signed-in macOS user, not root."
  exit 2
fi
if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
  print -u2 "CODEX_REMOTE_DEBUG_PORT must be between 1024 and 65535."
  exit 2
fi
if [[ ! "$startup_delay_seconds" =~ ^[0-9]+$ ]] || (( startup_delay_seconds > 600 )); then
  print -u2 "CODEX_STARTUP_DELAY_SECONDS must be between 0 and 600."
  exit 2
fi
if [[ ! "$mobile_ready_timeout_seconds" =~ ^[0-9]+$ ]] || (( mobile_ready_timeout_seconds < 5 || mobile_ready_timeout_seconds > 120 )); then
  print -u2 "CODEX_MOBILE_READY_TIMEOUT_SECONDS must be between 5 and 120."
  exit 2
fi

resolve_node() {
  local candidates=(
    "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"
    "$HOME/Library/Application Support/ChatGPTRemoteEnabler/node/bin/node"
    "/opt/homebrew/bin/node"
    "/usr/local/bin/node"
    "${commands[node]:-}"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]] &&
       "$candidate" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 && typeof WebSocket === "function" ? 0 : 1)' >/dev/null 2>&1; then
      print -r -- "$candidate"
      return 0
    fi
  done
  print -u2 "A Node.js runtime with built-in WebSocket support was not found."
  return 1
}

computer_name() {
  /usr/sbin/scutil --get LocalHostName 2>/dev/null || hostname -s
}

debug_endpoint_ready() {
  local node_bin="$1"
  /usr/bin/curl --silent --fail --max-time 1 "http://127.0.0.1:$port/json" 2>/dev/null \
    | "$node_bin" -e '
      let text = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", (chunk) => { text += chunk; });
      process.stdin.on("end", () => {
        try {
          const targets = JSON.parse(text);
          process.exit(Array.isArray(targets) && targets.some((target) => target?.url === "app://-/index.html") ? 0 : 1);
        } catch {
          process.exit(1);
        }
      });
    '
}

app_is_running() {
  /usr/bin/pgrep -x "$app_name" >/dev/null 2>&1 || /usr/bin/pgrep -x ChatGPT >/dev/null 2>&1 || /usr/bin/pgrep -x Codex >/dev/null 2>&1
}

recover_update() {
  (( update_recovered )) && return 0
  update_recovered=1
  if [[ -f "$updater" ]]; then
    local started=$EPOCHREALTIME output
    output="$(CHATGPT_REMOTE_LAUNCH_GUARD_HELD=1 CHATGPT_REMOTE_UPDATE_INSTALL_ROOT="$bundle_root" /bin/zsh "$updater" recover --launch-lock-held)" \
      || { print -u2 "Update recovery failed before launch."; return 1; }
    print -r -- "$output"
    print "stage=update-recovery durationMs=$(( (EPOCHREALTIME - started) * 1000 ))"
  fi
}

run_injector() {
  local node_bin="$1"
  local requested_action="$2"
  local args=("$injector" --action "$requested_action" --port "$port" --local-name "$(computer_name)" --target-wait-ms 30000)
  if [[ -n "$peer_name" ]]; then args+=(--single-remote-name "$peer_name"); fi
  "$node_bin" "${args[@]}"
}

readiness_state() {
  local node_bin="$1" json="$2"
  "$node_bin" -e '
    const value = JSON.parse(process.argv[1]);
    const report = value?.report;
    const fields = ["mounted", "localRuntimeReady", "authoritativeInventoryReady", "publisherReady", "ready"];
    if (!report || fields.some((name) => typeof report[name] !== "boolean")) {
      process.stderr.write("The mobile project view returned incomplete readiness proof.\n");
      process.exit(2);
    }
    if (typeof report.error === "string" && report.error.trim()) {
      process.stderr.write(`The mobile project view reported a terminal readiness error: ${report.error.slice(0, 240)}\n`);
      process.exit(2);
    }
    process.stdout.write(JSON.stringify(Object.fromEntries(fields.map((name) => [name, report[name]])));
    process.exit(report.ready ? 0 : 3);
  ' "$json"
}

capture_app_identity() {
  local app_path executable_name executable_path bundle_id pid_value start_token command_line
  app_path="$(/usr/bin/osascript - "$app_name" <<'APPLESCRIPT'
on run argv
  return POSIX path of (path to application (item 1 of argv))
end run
APPLESCRIPT
)"
  app_path="${app_path%/}"
  [[ "$app_path" == /* && -d "$app_path" ]] || { print -u2 "The exact application bundle could not be resolved."; return 1; }
  executable_name="$(/usr/bin/defaults read "$app_path/Contents/Info" CFBundleExecutable)"
  bundle_id="$(/usr/bin/defaults read "$app_path/Contents/Info" CFBundleIdentifier)"
  executable_path="$app_path/Contents/MacOS/$executable_name"
  [[ -x "$executable_path" && "$bundle_id" != *[^A-Za-z0-9.-]* ]] || { print -u2 "The exact application bundle identity is invalid."; return 1; }
  local candidates=()
  local candidate
  for candidate in $(/usr/bin/pgrep -x "$executable_name" 2>/dev/null || true); do
    command_line="$(/bin/ps -p "$candidate" -o command= 2>/dev/null || true)"
    [[ "$command_line" == *"--type="* ]] && continue
    [[ "$command_line" == *"--remote-debugging-port=$port"* || "$command_line" == *"--remote-debugging-port $port"* ]] || continue
    candidates+=("$candidate")
  done
  (( ${#candidates[@]} == 1 )) || { print -u2 "Expected one exact application process for renderer port $port; found ${#candidates[@]}."; return 1; }
  pid_value="${candidates[1]}"
  start_token="$(/bin/ps -p "$pid_value" -o lstart= | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  local actual_executable="$(/bin/ps -p "$pid_value" -o comm= | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -n "$start_token" && "$actual_executable" == "$executable_path" ]] || { print -u2 "The exact application process changed during capture."; return 1; }
  print -r -- "$pid_value"$'\t'"$start_token"$'\t'"$executable_path"$'\t'"$app_path"$'\t'"$bundle_id"
}

start_update_session() {
  local node_bin="$1" identity="$2"
  local state_root="$HOME/Library/Application Support/ChatGPTRemoteEnabler/update-sessions"
  local source name fingerprint="" bundle_hash bundle session_directory config_path
  local -a names=(update-session.js update-session-cdp.js UpdateSessionPlatform.sh cdp.js Update-ChatGPTRemote.sh update-transaction.js)
  local -a sources=("$update_session_source" "$update_session_cdp_source" "$update_session_platform_source" "$cdp_source" "$updater" "$update_transaction_source")
  for source in "${sources[@]}"; do [[ -f "$source" && ! -L "$source" ]] || { print -u2 "Update-session dependency is missing: $source"; return 1; }; done
  local index
  for (( index=1; index<=${#sources[@]}; index++ )); do
    fingerprint+="${names[$index]}:$(/usr/bin/shasum -a 256 "${sources[$index]}" | /usr/bin/awk '{print $1}')\n"
  done
  bundle_hash="$(print -rn -- "$fingerprint" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  bundle="$state_root/bundles/$bundle_hash"
  if [[ ! -d "$bundle" ]]; then
    mkdir -p "$state_root/bundles"
    local temporary="$state_root/bundles/.pending-$$-$RANDOM"
    mkdir -m 700 "$temporary"
    for (( index=1; index<=${#sources[@]}; index++ )); do cp -p -- "${sources[$index]}" "$temporary/${names[$index]}"; done
    chmod 700 "$temporary/UpdateSessionPlatform.sh" "$temporary/Update-ChatGPTRemote.sh"
    mv -- "$temporary" "$bundle" 2>/dev/null || { [[ -d "$bundle" ]] || return 1; rm -rf -- "$temporary"; }
  fi
  for (( index=1; index<=${#sources[@]}; index++ )); do
    [[ "$(/usr/bin/shasum -a 256 "$bundle/${names[$index]}" | /usr/bin/awk '{print $1}')" == "$(/usr/bin/shasum -a 256 "${sources[$index]}" | /usr/bin/awk '{print $1}')" ]] \
      || { print -u2 "Detached update-session bundle is incomplete: ${names[$index]}"; return 1; }
  done
  session_directory="$state_root/sessions/$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]')"
  mkdir -m 700 -p "$session_directory"
  config_path="$session_directory/session.json"
  local pid_value start_token executable_path app_path bundle_id
  IFS=$'\t' read -r pid_value start_token executable_path app_path bundle_id <<< "$identity"
  local automatic=true
  case "${CHATGPT_REMOTE_AUTO_UPDATE:-1}" in 0|false|FALSE|off|OFF|no|NO) automatic=false ;; esac
  [[ -f "$HOME/Library/Application Support/ChatGPTRemoteEnabler/update/auto-update-disabled" ]] && automatic=false
  "$node_bin" -e '
    const fs = require("node:fs");
    const [file, installRoot, stateRoot, sessionDirectory, updaterPath, platformHelperPath, port, automatic, skip, pid, startToken, executablePath, appPath, bundleId, appName, peerName, requiredPath, startupMode] = process.argv.slice(1);
    const value = { schemaVersion:1, platform:"darwin", installRoot, stateRoot, sessionDirectory, updaterPath, platformHelperPath,
      rendererPort:Number(port), autoCheckEnabled:automatic === "true", skipInitialCheck:skip === "1", logPath:sessionDirectory + "/update-session.log",
      app:{ pid:Number(pid), startToken, executablePath, appPath, bundleId },
      relaunch:{ entryPointRelative:"MobileProjectView-macOS-arm64.sh", startupMode:startupMode === "true", environment:{ CODEX_APP_NAME:appName, CODEX_REMOTE_PEER_NAME:peerName, CODEX_STARTUP_REQUIRED_PATH:requiredPath } } };
    const temporary = file + ".tmp";
    fs.writeFileSync(temporary, JSON.stringify(value, null, 2) + "\n", { encoding:"utf8", mode:0o600 });
    fs.renameSync(temporary, file);
  ' "$config_path" "$bundle_root" "$state_root" "$session_directory" "$bundle/Update-ChatGPTRemote.sh" "$bundle/UpdateSessionPlatform.sh" "$port" "$automatic" "$skip_update_check_once" "$pid_value" "$start_token" "$executable_path" "$app_path" "$bundle_id" "$app_name" "$peer_name" "$startup_required_path" "$([[ "$action" == startup ]] && print true || print false)"
  "$node_bin" --no-warnings "$bundle/update-session.js" --config "$config_path" --best-effort </dev/null >>"$session_directory/helper.log" 2>&1 &!
  print "Update session started for exact application process $pid_value."
}

write_relaunch_handoff() {
  local handoff_path="${CODEX_REMOTE_RELAUNCH_HANDOFF_PATH:-}"
  [[ -n "$handoff_path" ]] || return 0
  local allowed_root="$HOME/Library/Application Support/ChatGPTRemoteEnabler/update-sessions/sessions/"
  [[ "$handoff_path" == "$allowed_root"*/relaunch-handoff.json && "$handoff_path" != *$'\n'* ]] \
    || { print -u2 "The relaunch handoff path is outside the per-user update-session state."; return 1; }
  local temporary="$handoff_path.tmp"
  mkdir -p "${handoff_path:h}"
  print -r -- '{"ready":true,"entryPointRelative":"MobileProjectView-macOS-arm64.sh"}' > "$temporary"
  chmod 600 "$temporary"
  mv -f -- "$temporary" "$handoff_path"
}

enable_view() {
  acquire_launch_guard
  recover_update
  local node_bin
  node_bin="$(resolve_node)"
  if ! debug_endpoint_ready "$node_bin"; then
    if app_is_running; then
      print -u2 "$app_name is already running without the required loopback renderer endpoint. Quit it normally and reopen it with the ChatGPT Custom shortcut; refusing to start a second instance."
      return 1
    fi
    local maintenance_started=$EPOCHREALTIME
    "$node_bin" --no-warnings "$maintenance_helper" --best-effort
    print "stage=maintenance durationMs=$(( (EPOCHREALTIME - maintenance_started) * 1000 ))"
    /usr/bin/open -na "$app_name" --args --remote-debugging-address=127.0.0.1 --remote-debugging-port="$port"
    local attempt
    for attempt in {1..60}; do
      debug_endpoint_ready "$node_bin" && break
      sleep 0.5
    done
  fi
  debug_endpoint_ready "$node_bin" || { print -u2 "The loopback Codex renderer endpoint did not become ready."; return 1; }
  local mobile_started=$EPOCHREALTIME output summary readiness_exit deadline
  output="$(run_injector "$node_bin" enable)"
  print -r -- "$output"
  set +e
  summary="$(readiness_state "$node_bin" "$output")"
  readiness_exit=$?
  set -e
  (( readiness_exit == 2 )) && return 1
  deadline=$(( EPOCHSECONDS + mobile_ready_timeout_seconds ))
  while (( readiness_exit == 3 )); do
    (( EPOCHSECONDS < deadline )) || { print -u2 "The mobile project view did not become ready within $mobile_ready_timeout_seconds seconds."; return 1; }
    sleep 0.5
    output="$(run_injector "$node_bin" probe)"
    set +e
    summary="$(readiness_state "$node_bin" "$output")"
    readiness_exit=$?
    set -e
    (( readiness_exit == 2 )) && return 1
  done
  (( readiness_exit == 0 )) || { print -u2 "The mobile project view readiness probe failed."; return 1; }
  print "stage=mobile-readiness durationMs=$(( (EPOCHREALTIME - mobile_started) * 1000 )) proof=$summary"
  local identity
  identity="$(capture_app_identity)" || { print -u2 "Update status is unavailable because the exact application identity could not be captured."; return 0; }
  start_update_session "$node_bin" "$identity" || print -u2 "Update status is unavailable for this session."
  write_relaunch_handoff
}

startup_view() {
  if [[ "${CODEX_REMOTE_SKIP_STARTUP_DELAY_ONCE:-0}" != 1 ]]; then
    print "Delaying ChatGPT Mobile Projects startup for $startup_delay_seconds seconds."
    sleep "$startup_delay_seconds"
  else
    print "Skipping the one-time startup delay after a verified update."
  fi
  if [[ -n "$startup_required_path" && ! -d "$startup_required_path" ]]; then
    print -u2 "Required startup project path is unavailable after the delay: $startup_required_path"
    return 1
  fi
  enable_view
}

install_startup() {
  if [[ "$script_path" == /Volumes/* ]]; then
    print -u2 "Refusing a LaunchAgent that depends on a mounted volume. Copy both sibling bundles to local storage and run install-startup from the local copy."
    return 1
  fi
  mkdir -p "$launch_agents" "$rollback_root" "$log_root"
  chmod 755 "$script_path"
  local stamp="$(date +%Y%m%d-%H%M%S)-$$"
  local previous_plist="$rollback_root/$label-$stamp.plist"
  local previous_exists=0
  if [[ -e "$plist" ]]; then
    cp -p "$plist" "$previous_plist"
    previous_exists=1
  fi
  local temporary_plist="$plist.tmp.$$"
  rm -f -- "$temporary_plist"
  /usr/bin/plutil -create xml1 "$temporary_plist"
  /usr/libexec/PlistBuddy -c "Add :Label string $label" "$temporary_plist"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$temporary_plist"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $script_path" "$temporary_plist"
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string startup" "$temporary_plist"
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$temporary_plist"
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:CODEX_STARTUP_DELAY_SECONDS string $startup_delay_seconds" "$temporary_plist"
  if [[ -n "$startup_required_path" ]]; then
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:CODEX_STARTUP_REQUIRED_PATH string $startup_required_path" "$temporary_plist"
  fi
  /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$temporary_plist"
  /usr/libexec/PlistBuddy -c "Add :ProcessType string Interactive" "$temporary_plist"
  /usr/libexec/PlistBuddy -c "Add :StandardOutPath string $stdout_log" "$temporary_plist"
  /usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $stderr_log" "$temporary_plist"
  /usr/bin/plutil -lint "$temporary_plist" >/dev/null
  mv -f "$temporary_plist" "$plist"
  chmod 600 "$plist"
  /bin/launchctl bootout "gui/$UID" "$plist" 2>/dev/null || true
  if ! /bin/launchctl bootstrap "gui/$UID" "$plist" \
    || ! /bin/launchctl print "gui/$UID/$label" >/dev/null; then
    /bin/launchctl bootout "gui/$UID" "$plist" 2>/dev/null || true
    local failed_plist="$rollback_root/$label-failed-$stamp.plist"
    mv -f -- "$plist" "$failed_plist" 2>/dev/null || true
    if (( previous_exists )); then
      cp -p -- "$previous_plist" "$plist"
      if ! /bin/launchctl bootstrap "gui/$UID" "$plist" \
        || ! /bin/launchctl print "gui/$UID/$label" >/dev/null; then
        print -u2 "New LaunchAgent failed and the preserved previous LaunchAgent could not be reloaded: $previous_plist"
        return 1
      fi
      print -u2 "New LaunchAgent failed to load; the previous definition was restored."
    else
      print -u2 "New LaunchAgent failed to load; no previous definition existed."
    fi
    return 1
  fi
  print "Installed and loaded $plist"
}

remove_startup() {
  mkdir -p "$rollback_root"
  /bin/launchctl bootout "gui/$UID" "$plist" 2>/dev/null || true
  if [[ -e "$plist" ]]; then
    mv "$plist" "$rollback_root/$label-removed-$(date +%Y%m%d-%H%M%S)-$$.plist"
  fi
  print "Removed $label; the previous plist was preserved in $rollback_root"
}

case "$action" in
  enable) enable_view ;;
  startup) startup_view ;;
  disable) run_injector "$(resolve_node)" disable ;;
  probe) run_injector "$(resolve_node)" probe ;;
  enable-auto-registration) run_injector "$(resolve_node)" auto-on ;;
  disable-auto-registration) run_injector "$(resolve_node)" auto-off ;;
  enable-auto-archive) run_injector "$(resolve_node)" archive-auto-on ;;
  disable-auto-archive) run_injector "$(resolve_node)" archive-auto-off ;;
  preview-auto-archive) run_injector "$(resolve_node)" archive-preview ;;
  run-auto-archive) run_injector "$(resolve_node)" archive-run ;;
  enable-auto-maintenance) run_injector "$(resolve_node)" maintenance-auto-on ;;
  disable-auto-maintenance) run_injector "$(resolve_node)" maintenance-auto-off ;;
  preview-auto-maintenance) run_injector "$(resolve_node)" maintenance-preview ;;
  run-auto-maintenance) run_injector "$(resolve_node)" maintenance-run ;;
  reconcile-auto-registrations) run_injector "$(resolve_node)" auto-reconcile ;;
  remove-auto-registrations) run_injector "$(resolve_node)" auto-remove ;;
  install-startup) install_startup ;;
  remove-startup) remove_startup ;;
  *) print -u2 "Usage: $0 {enable|startup|disable|probe|enable-auto-registration|disable-auto-registration|enable-auto-maintenance|disable-auto-maintenance|preview-auto-maintenance|run-auto-maintenance|reconcile-auto-registrations|remove-auto-registrations|install-startup|remove-startup}"; exit 2 ;;
esac
