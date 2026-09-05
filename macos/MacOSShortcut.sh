#!/bin/zsh
set -euo pipefail

action="${1:-probe}"
action="${action:l}"
script_path="${0:A}"
launcher="${script_path:h}/MobileProjectView-macOS-arm64.sh"
source_root="$HOME/Library/Application Support/CodexRemoteFeatures/launchers"
source_file="$source_root/ChatGPT Remote Enabler.applescript"
app_root="$HOME/Applications"
app_path="$app_root/ChatGPT Remote Enabler.app"
rollback_root="$source_root/rollback"

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
  [[ -f "$checked_source" ]] || { print -u2 "AppleScript source is missing: $checked_source"; return 1; }
  [[ -d "$checked_app" ]] || { print -u2 "Application wrapper is missing: $checked_app"; return 1; }
  /usr/bin/codesign --verify --deep --strict "$checked_app"
  local escaped_launcher="$(escape_applescript_string "$launcher")"
  /usr/bin/osadecompile "$checked_app" | /usr/bin/grep -F "set launcherPath to \"$escaped_launcher\"" >/dev/null
  print "Shortcut is valid: $checked_app"
}

install_shortcut() {
  [[ -f "$launcher" ]] || { print -u2 "Installed launcher is missing: $launcher"; return 1; }
  mkdir -p "$source_root" "$app_root" "$rollback_root"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  local candidate_source="$source_root/.ChatGPT Remote Enabler.applescript.tmp.$$"
  local candidate_app="$app_root/.ChatGPT Remote Enabler.app.tmp.$$"
  rm -rf -- "$candidate_source" "$candidate_app"
  local escaped_launcher="$(escape_applescript_string "$launcher")"
  /bin/cat > "$candidate_source" <<APPLESCRIPT
on run
    set launcherPath to "$escaped_launcher"
    try
        set runningCount to do shell script "{ /usr/bin/pgrep -x ChatGPT; /usr/bin/pgrep -x Codex; } | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' '"
        if runningCount is not "0" then
            display alert "ChatGPT is already running" message "Quit ChatGPT with Command-Q when no task is active, then click ChatGPT Remote Enabler again. The launcher will not terminate it automatically." as warning
            return
        end if
        do shell script "/bin/zsh " & quoted form of launcherPath & " enable"
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
  local previous_source="$rollback_root/ChatGPT Remote Enabler-$stamp.applescript"
  local previous_app="$rollback_root/ChatGPT Remote Enabler-$stamp.app"
  local source_preserved=0 app_preserved=0
  if [[ -f "$source_file" ]]; then
    if ! mv -- "$source_file" "$previous_source"; then
      rm -rf -- "$candidate_source" "$candidate_app"
      return 1
    fi
    source_preserved=1
  fi
  if [[ -e "$app_path" ]]; then
    if ! mv -- "$app_path" "$previous_app"; then
      (( source_preserved )) && mv -- "$previous_source" "$source_file"
      rm -rf -- "$candidate_source" "$candidate_app"
      return 1
    fi
    app_preserved=1
  fi
  if ! mv -- "$candidate_source" "$source_file" || ! mv -- "$candidate_app" "$app_path"; then
    rm -rf -- "$source_file" "$app_path" "$candidate_source" "$candidate_app"
    (( source_preserved )) && mv -- "$previous_source" "$source_file"
    (( app_preserved )) && mv -- "$previous_app" "$app_path"
    print -u2 "Shortcut replacement failed; the previous shortcut was restored."
    return 1
  fi
  if ! probe_shortcut; then
    rm -rf -- "$source_file" "$app_path"
    (( source_preserved )) && mv -- "$previous_source" "$source_file"
    (( app_preserved )) && mv -- "$previous_app" "$app_path"
    print -u2 "Installed shortcut failed final validation; the previous shortcut was restored."
    return 1
  fi
}

remove_shortcut() {
  mkdir -p "$rollback_root"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  if [[ -e "$app_path" ]]; then
    mv "$app_path" "$rollback_root/ChatGPT Remote Enabler-removed-$stamp.app"
  fi
  if [[ -f "$source_file" ]]; then
    mv "$source_file" "$rollback_root/ChatGPT Remote Enabler-removed-$stamp.applescript"
  fi
  print "Shortcut files were preserved under $rollback_root. Remove the stale Dock icon manually if present."
}

case "$action" in
  install) install_shortcut ;;
  probe) probe_shortcut ;;
  remove) remove_shortcut ;;
  reveal) probe_shortcut; /usr/bin/open -R "$app_path" ;;
  *) print -u2 "Usage: $0 {install|probe|reveal|remove}"; exit 2 ;;
esac
