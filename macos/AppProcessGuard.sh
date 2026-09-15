#!/bin/zsh
set -euo pipefail

action="${1:-running}"
shift || true
typeset -a app_names executable_paths
app_names=("${CODEX_APP_NAME:-ChatGPT}" ChatGPT Codex)
executable_paths=()
process_list_file=""

while (( $# )); do
  case "$1" in
    --app-name)
      (( $# >= 2 )) || { print -u2 'The --app-name option requires a value.'; exit 2; }
      app_names+=("$2")
      shift 2
      ;;
    --executable)
      (( $# >= 2 )) || { print -u2 'The --executable option requires a path.'; exit 2; }
      [[ "$2" == /* ]] || { print -u2 'Executable paths must be absolute.'; exit 2; }
      executable_paths+=("$2")
      shift 2
      ;;
    --process-list-file)
      (( $# >= 2 )) || { print -u2 'The --process-list-file option requires a path.'; exit 2; }
      [[ "$2" == /* ]] || { print -u2 'The process-list fixture path must be absolute.'; exit 2; }
      process_list_file="$2"
      shift 2
      ;;
    *) print -u2 "Unsupported process-guard option: $1"; exit 2 ;;
  esac
done

add_app_executable_paths() {
  local name="$1" bundle executable
  [[ -n "$name" && "$name" != *$'\n'* && "$name" != */* ]] || return 0
  for bundle in "/Applications/$name.app" "$HOME/Applications/$name.app"; do
    [[ -d "$bundle" && ! -L "$bundle" ]] || continue
    executable="$(/usr/bin/defaults read "$bundle/Contents/Info" CFBundleExecutable 2>/dev/null || true)"
    [[ -n "$executable" && "$executable" != */* ]] || executable="$name"
    executable_paths+=("$bundle/Contents/MacOS/$executable")
  done
  # Keep standard paths available even when a fixture or an early install does
  # not expose the application bundle metadata yet.
  executable_paths+=("/Applications/$name.app/Contents/MacOS/$name" "$HOME/Applications/$name.app/Contents/MacOS/$name")
}

if (( ${#executable_paths[@]} == 0 )); then
  local_app_name=""
  for local_app_name in "${app_names[@]}"; do add_app_executable_paths "$local_app_name"; done
fi

typeset -a unique_paths
unique_paths=()
local_path=""
for local_path in "${executable_paths[@]}"; do
  (( ${unique_paths[(Ie)$local_path]} )) || unique_paths+=("$local_path")
done

match_processes() {
  /usr/bin/awk -v paths="${(j:\034:)unique_paths}" '
    BEGIN { count = split(paths, expected, "\034") }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      pid = line
      sub(/[[:space:]].*$/, "", pid)
      command = line
      sub(/^[^[:space:]]+[[:space:]]+/, "", command)
      for (position = 1; position <= count; position += 1) {
        path = expected[position]
        if (command == path || index(command, path " ") == 1 || index(command, path "\t") == 1) {
          print pid "\t" command
          break
        }
      }
    }
  '
}

enumerate_processes() {
  local process_list matches
  if [[ -n "$process_list_file" ]]; then
    process_list="$(/bin/cat -- "$process_list_file")" || return 2
  else
    process_list="$(/bin/ps -axo pid=,command=)" || return 2
  fi
  matches="$(print -r -- "$process_list" | match_processes)" || return 2
  print -r -- "$matches"
}

case "$action" in
  match-stdin) match_processes ;;
  list) enumerate_processes ;;
  running)
    first="$(enumerate_processes)" || exit 2
    [[ -n "$first" ]]
    ;;
  *) print -u2 "Usage: $0 {running|list|match-stdin} [--app-name name] [--executable path]"; exit 2 ;;
esac
