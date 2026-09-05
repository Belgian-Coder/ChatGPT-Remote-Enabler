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

node_bin="$(command -v node)"
transaction_helper="$root/macos/update-transaction.js"
install_root="$temporary/install"
prepared_root="$temporary/prepared"
state_root="$temporary/state"
mkdir -p "$install_root" "$prepared_root" "$state_root"
print -r -- v1.0.0 > "$install_root/VERSION"
print -r -- old > "$install_root/payload.txt"
print -r -- removed > "$install_root/removed.txt"
{
  print -r -- "$(/usr/bin/shasum -a 256 "$install_root/VERSION" | /usr/bin/awk '{print $1}') *VERSION"
  print -r -- "$(/usr/bin/shasum -a 256 "$install_root/payload.txt" | /usr/bin/awk '{print $1}') *payload.txt"
  print -r -- "$(/usr/bin/shasum -a 256 "$install_root/removed.txt" | /usr/bin/awk '{print $1}') *removed.txt"
} > "$install_root/RELEASE-MANIFEST.sha256"
print -r -- v2.0.0 > "$prepared_root/VERSION"
print -r -- new > "$prepared_root/payload.txt"
print -r -- added > "$prepared_root/added.txt"
cp -p -- "$root/macos/Update-ChatGPTRemote.sh" "$prepared_root/Update-ChatGPTRemote.sh"
cp -p -- "$transaction_helper" "$prepared_root/update-transaction.js"
{
  print -r -- "$(/usr/bin/shasum -a 256 "$prepared_root/VERSION" | /usr/bin/awk '{print $1}') *VERSION"
  print -r -- "$(/usr/bin/shasum -a 256 "$prepared_root/payload.txt" | /usr/bin/awk '{print $1}') *payload.txt"
  print -r -- "$(/usr/bin/shasum -a 256 "$prepared_root/added.txt" | /usr/bin/awk '{print $1}') *added.txt"
  print -r -- "$(/usr/bin/shasum -a 256 "$prepared_root/Update-ChatGPTRemote.sh" | /usr/bin/awk '{print $1}') *Update-ChatGPTRemote.sh"
  print -r -- "$(/usr/bin/shasum -a 256 "$prepared_root/update-transaction.js" | /usr/bin/awk '{print $1}') *update-transaction.js"
} > "$prepared_root/RELEASE-MANIFEST.sha256"
print -rn -- fixture-archive > "$prepared_root/.chatgpt-remote-release.zip"
archive_hash="$(/usr/bin/shasum -a 256 "$prepared_root/.chatgpt-remote-release.zip" | /usr/bin/awk '{print $1}')"
"$node_bin" "$transaction_helper" seal-prepared --prepared-root "$prepared_root" --platform macOS-arm64 --version v2.0.0 --archive-sha256 "$archive_hash" >/dev/null
apply_result="$("$node_bin" "$transaction_helper" apply --install-root "$install_root" --prepared-root "$prepared_root" \
  --journal-path "$state_root/transaction.json" --backup-root "$state_root/rollback" --platform macOS-arm64 \
  --version v2.0.0 --archive-sha256 "$archive_hash")"
[[ "$apply_result" == *'"updated":true'* && "$(<"$install_root/payload.txt")" == new && ! -e "$install_root/removed.txt" ]] || {
  print -u2 "Transactional macOS apply produced the wrong fixture state."
  exit 1
}
"$node_bin" "$transaction_helper" integrity --install-root "$install_root" >/dev/null

print -r -- '{"AppleScriptEscapeSemantic":true,"SharedEscapeHelper":true,"MacOSShellSyntax":true,"RelativeInvocation":true,"TransactionApply":true}'
