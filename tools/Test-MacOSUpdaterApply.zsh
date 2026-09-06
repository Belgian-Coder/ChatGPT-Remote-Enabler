#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
updater="$root/macos/Update-ChatGPTRemote.sh"
transaction_helper="$root/macos/update-transaction.js"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-remote-macos-updater-apply.XXXXXX")"
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT INT TERM

fixture_home="$temporary/home"
install_root="$temporary/install"
prepared_root="$temporary/prepared"
mkdir -p "$fixture_home" "$install_root" "$prepared_root"

cp -p -- "$updater" "$install_root/Update-ChatGPTRemote.sh"
cp -p -- "$transaction_helper" "$install_root/update-transaction.js"
for name in MacOSShortcut.sh MobileProjectView-macOS-arm64.sh Setup.command UpdateSessionPlatform.sh; do
  cp -p -- "$updater" "$install_root/$name"
done
/bin/chmod 755 "$install_root"/*.sh "$install_root"/*.command
print -r -- v1.5.40 > "$install_root/VERSION"
print -r -- old > "$install_root/payload.txt"
print -r -- removed > "$install_root/removed.txt"
{
  print -r -- "$(/usr/bin/shasum -a 256 "$install_root/Update-ChatGPTRemote.sh" | /usr/bin/awk '{print $1}') *Update-ChatGPTRemote.sh"
  print -r -- "$(/usr/bin/shasum -a 256 "$install_root/update-transaction.js" | /usr/bin/awk '{print $1}') *update-transaction.js"
  print -r -- "$(/usr/bin/shasum -a 256 "$install_root/VERSION" | /usr/bin/awk '{print $1}') *VERSION"
  print -r -- "$(/usr/bin/shasum -a 256 "$install_root/payload.txt" | /usr/bin/awk '{print $1}') *payload.txt"
  print -r -- "$(/usr/bin/shasum -a 256 "$install_root/removed.txt" | /usr/bin/awk '{print $1}') *removed.txt"
  for name in MacOSShortcut.sh MobileProjectView-macOS-arm64.sh Setup.command UpdateSessionPlatform.sh; do
    print -r -- "$(/usr/bin/shasum -a 256 "$install_root/$name" | /usr/bin/awk '{print $1}') *$name"
  done
} > "$install_root/RELEASE-MANIFEST.sha256"

cp -p -- "$updater" "$prepared_root/Update-ChatGPTRemote.sh"
cp -p -- "$transaction_helper" "$prepared_root/update-transaction.js"
for name in MacOSShortcut.sh MobileProjectView-macOS-arm64.sh Setup.command UpdateSessionPlatform.sh; do
  cp -p -- "$updater" "$prepared_root/$name"
done
/bin/chmod 644 "$prepared_root"/*.sh "$prepared_root"/*.command
print -r -- v1.5.41 > "$prepared_root/VERSION"
print -r -- new > "$prepared_root/payload.txt"
print -r -- added > "$prepared_root/added.txt"
{
  print -r -- "$(/usr/bin/shasum -a 256 "$prepared_root/Update-ChatGPTRemote.sh" | /usr/bin/awk '{print $1}') *Update-ChatGPTRemote.sh"
  print -r -- "$(/usr/bin/shasum -a 256 "$prepared_root/update-transaction.js" | /usr/bin/awk '{print $1}') *update-transaction.js"
  print -r -- "$(/usr/bin/shasum -a 256 "$prepared_root/VERSION" | /usr/bin/awk '{print $1}') *VERSION"
  print -r -- "$(/usr/bin/shasum -a 256 "$prepared_root/payload.txt" | /usr/bin/awk '{print $1}') *payload.txt"
  print -r -- "$(/usr/bin/shasum -a 256 "$prepared_root/added.txt" | /usr/bin/awk '{print $1}') *added.txt"
  for name in MacOSShortcut.sh MobileProjectView-macOS-arm64.sh Setup.command UpdateSessionPlatform.sh; do
    print -r -- "$(/usr/bin/shasum -a 256 "$prepared_root/$name" | /usr/bin/awk '{print $1}') *$name"
  done
} > "$prepared_root/RELEASE-MANIFEST.sha256"
print -rn -- fixture-archive > "$prepared_root/.chatgpt-remote-release.zip"
archive_hash="$(/usr/bin/shasum -a 256 "$prepared_root/.chatgpt-remote-release.zip" | /usr/bin/awk '{print $1}')"
node_bin="$(command -v node)"
"$node_bin" "$transaction_helper" seal-prepared --prepared-root "$prepared_root" --platform macOS-arm64 \
  --version v1.5.41 --archive-sha256 "$archive_hash" >/dev/null

apply_result="$(HOME="$fixture_home" CHATGPT_REMOTE_UPDATE_INSTALL_ROOT="$install_root" \
  /bin/zsh "$install_root/Update-ChatGPTRemote.sh" apply-prepared \
  --target-version v1.5.41 --expected-archive-sha256 "$archive_hash" --prepared-directory "$prepared_root")"
rollback_path="$("$node_bin" -e 'const result = JSON.parse(process.argv[1]); if (!result.updated || result.version !== "v1.5.41" || !result.rollbackPath) process.exit(1); process.stdout.write(result.rollbackPath);' "$apply_result")"
[[ "$(<"$install_root/VERSION")" == v1.5.41 ]]
[[ "$(<"$install_root/payload.txt")" == new && "$(<"$install_root/added.txt")" == added ]]
[[ ! -e "$install_root/removed.txt" ]]
[[ -d "$rollback_path" && "$(<"$rollback_path/VERSION")" == v1.5.40 ]]
for name in MacOSShortcut.sh MobileProjectView-macOS-arm64.sh Setup.command Update-ChatGPTRemote.sh UpdateSessionPlatform.sh; do
  [[ -x "$install_root/$name" ]]
  [[ -x "$rollback_path/$name" ]]
done
[[ -f "$fixture_home/Library/Application Support/ChatGPTRemoteEnabler/update/last-check.json" ]]
[[ ! -f "$fixture_home/Library/Application Support/ChatGPTRemoteEnabler/update/transaction.json" ]]
[[ ! -d "$fixture_home/Library/Application Support/ChatGPTRemoteEnabler/update/update.lock" ]]
[[ ! -d "$fixture_home/Library/Application Support/ChatGPTRemoteEnabler/launch.lock" ]]

typeset unsafe_output
if unsafe_output="$(HOME="$fixture_home" CHATGPT_REMOTE_UPDATE_INSTALL_ROOT="$install_root" \
  /bin/zsh "$install_root/Update-ChatGPTRemote.sh" apply-prepared \
  --target-version v1.5.41 --expected-archive-sha256 "$archive_hash" --prepared-directory "$install_root" 2>&1)"; then
  print -u2 'The updater accepted an overlapping prepared and install root.'
  exit 1
fi
[[ "$unsafe_output" == *'Prepared directory must be separate from the install root.'* ]]

print -r -- '{"MacOSUpdaterApplyPrepared":true,"JsonResult":true,"InstalledVersion":"v1.5.41","RollbackRetained":true,"UnsafeRootRejected":true}'
