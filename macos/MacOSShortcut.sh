#!/bin/zsh
set -euo pipefail

action="${1:-probe}"
action="${action:l}"
use_proxy=0
[[ "${2:-}" == --proxy ]] && use_proxy=1
[[ $# -le 2 ]] || { print -u2 'Too many shortcut arguments.'; exit 2; }
[[ $# -lt 2 || "${2:-}" == --proxy ]] || { print -u2 'Unsupported shortcut argument.'; exit 2; }
script_path="${0:A}"
launcher="${script_path:h}/MobileProjectView-macOS-arm64.sh"
process_guard="${script_path:h}/AppProcessGuard.sh"
source_root="$HOME/Library/Application Support/CodexRemoteFeatures/launchers"
source_file="$source_root/ChatGPT Remote Enabler.applescript"
app_root="$HOME/Applications"
app_path="$app_root/ChatGPT Remote Enabler.app"
legacy_source_file="$source_root/ChatGPT Mobile Projects.applescript"
legacy_app_path="$app_root/ChatGPT Mobile Projects.app"
rollback_root="$source_root/rollback"
app_name="${CODEX_APP_NAME:-ChatGPT}"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  print -u2 "This shortcut manager is restricted to macOS on Apple Silicon (arm64)."
  exit 2
fi
if [[ "$EUID" -eq 0 ]]; then
  print -u2 "Run this as the signed-in macOS user, not root."
  exit 2
fi

escape_applescript_string() {
  local escaped="$1"
  escaped="${escaped//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  print -r -- "$escaped"
}

probe_shortcut() {
  local checked_app="${1:-$app_path}"
  local checked_source="${2:-$source_file}"
  [[ -f "$launcher" ]] || { print -u2 "Installed launcher is missing: $launcher"; return 1; }
  [[ -f "$process_guard" && ! -L "$process_guard" ]] || { print -u2 "Installed process guard is missing: $process_guard"; return 1; }
  [[ -f "$checked_source" ]] || { print -u2 "AppleScript source is missing: $checked_source"; return 1; }
  [[ -d "$checked_app" ]] || { print -u2 "Application wrapper is missing: $checked_app"; return 1; }
  /usr/bin/codesign --verify --deep --strict "$checked_app"
  local escaped_launcher="$(escape_applescript_string "$launcher")"
  local escaped_process_guard="$(escape_applescript_string "$process_guard")"
  /usr/bin/osadecompile "$checked_app" | /usr/bin/grep -F "set launcherPath to \"$escaped_launcher\"" >/dev/null
  /usr/bin/osadecompile "$checked_app" | /usr/bin/grep -F "set processGuardPath to \"$escaped_process_guard\"" >/dev/null
  local expected_suffix=""
  (( use_proxy )) && expected_suffix=' --proxy'
  /usr/bin/osadecompile "$checked_app" | /usr/bin/grep -F "quoted form of launcherPath & \" enable$expected_suffix\"" >/dev/null
  print "Shortcut is valid: $checked_app"
}

install_shortcut() {
  [[ -f "$launcher" ]] || { print -u2 "Installed launcher is missing: $launcher"; return 1; }
  [[ -f "$process_guard" && ! -L "$process_guard" ]] || { print -u2 "Installed process guard is missing: $process_guard"; return 1; }
  local shortcut_name="${1:-ChatGPT Remote Enabler}"
  local installed_source="${2:-$source_file}"
  local installed_app="${3:-$app_path}"
  mkdir -p "$source_root" "$app_root" "$rollback_root"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  local candidate_source="$source_root/.$shortcut_name.applescript.tmp.$$"
  local candidate_app="$app_root/.$shortcut_name.tmp.$$.$RANDOM.app"
  rm -rf -- "$candidate_source" "$candidate_app"
  local escaped_launcher="$(escape_applescript_string "$launcher")"
  local escaped_process_guard="$(escape_applescript_string "$process_guard")"
  local escaped_app_name="$(escape_applescript_string "$app_name")"
  local proxy_suffix=""
  (( use_proxy )) && proxy_suffix=' --proxy'
  /bin/cat > "$candidate_source" <<APPLESCRIPT
on run
    set launcherPath to "$escaped_launcher"
    set processGuardPath to "$escaped_process_guard"
    set guardedAppName to "$escaped_app_name"
    try
        set runningState to do shell script "/bin/zsh " & quoted form of processGuardPath & " running --app-name " & quoted form of guardedAppName & " >/dev/null 2>&1; status=\$?; if [ \$status -eq 0 ]; then echo running; elif [ \$status -eq 1 ]; then echo stopped; else exit \$status; fi"
        if runningState is "running" then
            display alert "ChatGPT is already running" message "Quit ChatGPT with Command-Q when no task is active, then click ChatGPT Remote Enabler again. The launcher will not terminate it automatically." as warning
            return
        end if
        do shell script "/bin/zsh " & quoted form of launcherPath & " enable$proxy_suffix"
    on error errorMessage number errorNumber
        display alert "ChatGPT Remote Enabler failed to start" message (errorMessage & " (error " & (errorNumber as text) & ")") as critical
    end try
end run
APPLESCRIPT
  if ! /usr/bin/osacompile -o "$candidate_app" "$candidate_source" \
    || ! /usr/bin/codesign --force --deep --sign - "$candidate_app" \
    || ! probe_shortcut "$candidate_app" "$candidate_source"; then
    rm -rf -- "$candidate_source" "$candidate_app"
    print -u2 "Shortcut candidate failed validation; the installed shortcut was left unchanged."
    return 1
  fi
  local previous_source="$rollback_root/$shortcut_name-$stamp.applescript"
  local previous_app="$rollback_root/$shortcut_name-$stamp.app"
  local source_preserved=0 app_preserved=0
  if [[ -f "$installed_source" ]]; then
    if ! mv -- "$installed_source" "$previous_source"; then
      rm -rf -- "$candidate_source" "$candidate_app"
      return 1
    fi
    source_preserved=1
  fi
  if [[ -e "$installed_app" ]]; then
    if ! mv -- "$installed_app" "$previous_app"; then
      if (( source_preserved )); then mv -- "$previous_source" "$installed_source"; fi
      rm -rf -- "$candidate_source" "$candidate_app"
      return 1
    fi
    app_preserved=1
  fi
  if ! mv -- "$candidate_source" "$installed_source" || ! mv -- "$candidate_app" "$installed_app"; then
    rm -rf -- "$installed_source" "$installed_app" "$candidate_source" "$candidate_app"
    if (( source_preserved )); then mv -- "$previous_source" "$installed_source"; fi
    if (( app_preserved )); then mv -- "$previous_app" "$installed_app"; fi
    print -u2 "Shortcut replacement failed; the previous shortcut was restored."
    return 1
  fi
  if ! probe_shortcut "$installed_app" "$installed_source"; then
    rm -rf -- "$installed_source" "$installed_app"
    if (( source_preserved )); then mv -- "$previous_source" "$installed_source"; fi
    if (( app_preserved )); then mv -- "$previous_app" "$installed_app"; fi
    print -u2 "Installed shortcut failed final validation; the previous shortcut was restored."
    return 1
  fi
  # The package updater owns the one previous package generation. Shortcut
  # swaps use rollback files only during this transaction and retain none after
  # a successful exact probe.
  if (( source_preserved )); then rm -f -- "$previous_source"; fi
  if (( app_preserved )); then rm -rf -- "$previous_app"; fi
  rmdir -- "$rollback_root" 2>/dev/null || true
}

remove_shortcut() {
  mkdir -p "$rollback_root"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  local previous_app="$rollback_root/ChatGPT Remote Enabler-removed-$stamp.app"
  local previous_source="$rollback_root/ChatGPT Remote Enabler-removed-$stamp.applescript"
  local app_preserved=0 source_preserved=0
  if [[ -e "$app_path" ]]; then
    mv -- "$app_path" "$previous_app"
    app_preserved=1
  fi
  if [[ -f "$source_file" ]]; then
    if ! mv -- "$source_file" "$previous_source"; then
      if (( app_preserved )); then mv -- "$previous_app" "$app_path"; fi
      print -u2 "Shortcut removal failed; the application wrapper was restored."
      return 1
    fi
    source_preserved=1
  fi
  if [[ -e "$app_path" || -f "$source_file" ]]; then
    if (( source_preserved )); then mv -- "$previous_source" "$source_file"; fi
    if (( app_preserved )); then mv -- "$previous_app" "$app_path"; fi
    print -u2 "Shortcut removal did not complete; the previous shortcut was restored."
    return 1
  fi
  if (( source_preserved )); then rm -f -- "$previous_source"; fi
  if (( app_preserved )); then rm -rf -- "$previous_app"; fi
  rmdir -- "$rollback_root" 2>/dev/null || true
  print "Shortcut removed."
}

case "$action" in
  install)
    legacy_exists=0
    [[ -d "$legacy_app_path" || -f "$legacy_source_file" ]] && legacy_exists=1
    install_shortcut
    if (( legacy_exists )); then
      install_shortcut 'ChatGPT Mobile Projects' "$legacy_source_file" "$legacy_app_path"
    fi
    ;;
  probe) probe_shortcut ;;
  remove) remove_shortcut ;;
  reveal) probe_shortcut; /usr/bin/open -R "$app_path" ;;
  *) print -u2 "Usage: $0 {install|probe|reveal|remove} [--proxy]"; exit 2 ;;
esac
