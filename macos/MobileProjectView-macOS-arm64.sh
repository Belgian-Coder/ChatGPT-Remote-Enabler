#!/bin/zsh
set -euo pipefail

action="${1:-probe}"
action="${action:l}"
script_path="${0:A}"
bundle_root="${script_path:h}"
injector="$bundle_root/inject.js"
maintenance_helper="$bundle_root/maintenance.js"
updater="$bundle_root/Update-ChatGPTRemote.sh"
update_checked=0
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

resolve_node() {
  local candidates=(
    "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"
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

maybe_auto_update() {
  (( update_checked )) && return 0
  update_checked=1
  if [[ -f "$updater" ]]; then
    /bin/zsh "$updater" auto || print -u2 "Automatic update was skipped; continuing with the installed version."
  fi
}

run_injector() {
  local node_bin="$1"
  local requested_action="$2"
  local args=("$injector" --action "$requested_action" --port "$port" --local-name "$(computer_name)" --target-wait-ms 30000)
  if [[ -n "$peer_name" ]]; then args+=(--single-remote-name "$peer_name"); fi
  "$node_bin" "${args[@]}"
}

enable_view() {
  maybe_auto_update
  local node_bin
  node_bin="$(resolve_node)"
  if ! debug_endpoint_ready "$node_bin"; then
    if app_is_running; then
      print -u2 "$app_name is already running without the required loopback renderer endpoint. Quit it normally and reopen it with the ChatGPT Custom shortcut; refusing to start a second instance."
      return 1
    fi
    "$node_bin" --no-warnings "$maintenance_helper"
    /usr/bin/open -na "$app_name" --args --remote-debugging-address=127.0.0.1 --remote-debugging-port="$port"
    local attempt
    for attempt in {1..60}; do
      debug_endpoint_ready "$node_bin" && break
      sleep 0.5
    done
  fi
  debug_endpoint_ready "$node_bin" || { print -u2 "The loopback Codex renderer endpoint did not become ready."; return 1; }
  run_injector "$node_bin" enable
}

startup_view() {
  print "Delaying ChatGPT Mobile Projects startup for $startup_delay_seconds seconds."
  sleep "$startup_delay_seconds"
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
