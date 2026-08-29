#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
shortcut="$root/macos/MacOSShortcut.sh"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-remote-macos-support.XXXXXX")"
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT INT TERM

sed -n '/^escape_applescript_string() {$/,/^}$/p' "$shortcut" > "$temporary/escape.zsh"
source "$temporary/escape.zsh"

input='/Users/example/Quoted "folder"/Back\slash/MobileProjectView-macOS-arm64.sh'
expected='/Users/example/Quoted \"folder\"/Back\\slash/MobileProjectView-macOS-arm64.sh'
actual="$(escape_applescript_string "$input")"
[[ "$actual" == "$expected" ]] || {
  print -u2 "AppleScript launcher escaping changed: $actual"
  exit 1
}

uses="$(grep -Fc 'escape_applescript_string "$launcher"' "$shortcut")"
[[ "$uses" == 2 ]] || { print -u2 "Installer and probe do not share one escape helper."; exit 1; }

for script in "$root"/macos/*.sh; do /bin/zsh -n "$script"; done

mkdir -p "$temporary/home"
relative_probe="$(cd "$root/macos" && HOME="$temporary/home" /bin/zsh ./Update-ChatGPTRemote.sh probe)"
[[ "$relative_probe" == *"\"installRoot\":\"$root/macos\""* ]] || {
  print -u2 "Relative updater invocation resolved against HOME instead of its original working directory."
  exit 1
}

sed -n '/^rollback_copies() {$/,/^}$/p' "$root/macos/Update-ChatGPTRemote.sh" > "$temporary/rollback.zsh"
source "$temporary/rollback.zsh"
typeset -a failure_points=(first.txt middle.txt Update-ChatGPTRemote.sh RELEASE-MANIFEST.sha256)
for failure_point in "${failure_points[@]}"; do
  install_root="$temporary/install-${failure_point//[^A-Za-z0-9]/_}"
  backup_root="$temporary/backup-${failure_point//[^A-Za-z0-9]/_}"
  mkdir -p "$install_root" "$backup_root"
  typeset -ga copied_relatives=() copied_existed=()
  for relative in "${failure_points[@]}"; do
    print -r -- "old-$relative" > "$install_root/$relative"
  done
  for relative in "${failure_points[@]}"; do
    cp -p -- "$install_root/$relative" "$backup_root/$relative"
    copied_relatives+=("$relative"); copied_existed+=(1)
    print -r -- partial-copy > "$install_root/$relative"
    if [[ "$relative" == "$failure_point" ]]; then
      rollback_copies "$backup_root"
      break
    fi
    print -r -- "new-$relative" > "$install_root/$relative"
  done
  for relative in "${failure_points[@]}"; do
    [[ "$(<"$install_root/$relative")" == "old-$relative" ]] || {
      print -u2 "Rollback did not restore $relative after injected $failure_point failure."
      exit 1
    }
  done
done

print -r -- '{"AppleScriptEscapeSemantic":true,"SharedEscapeHelper":true,"MacOSShellSyntax":true,"RelativeInvocation":true,"RollbackFailurePoints":4}'
