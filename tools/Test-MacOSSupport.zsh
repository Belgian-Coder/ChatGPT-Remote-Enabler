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

launcher="$root/macos/MobileProjectView-macOS-arm64.sh"
prelaunch_fixture="$temporary/prelaunch-functions.zsh"
for function_name in release_launch_guard acquire_launch_guard last_json_result recover_update prelaunch_update; do
  sed -n "/^${function_name}() {$/,/^}$/p" "$launcher" >> "$prelaunch_fixture"
done
source "$prelaunch_fixture"

bundle_root="$temporary/prelaunch-install"
updater="$bundle_root/Update-ChatGPTRemote.sh"
mkdir -p "$bundle_root"
cat > "$updater" <<'MOCK_UPDATER'
#!/bin/zsh
set -euo pipefail
[[ "${CHATGPT_REMOTE_LAUNCH_GUARD_HELD:-0}" == 1 ]]
[[ "${CHATGPT_REMOTE_UPDATE_INSTALL_ROOT:-}" == "${0:A:h}" ]]
[[ "${2:-}" == --launch-lock-held ]]
print -r -- "${1:-}" >> "$MOCK_CALL_LOG"
case "${1:-}" in
  recover)
    print 'mock recovery progress'
    if [[ "${MOCK_RECOVERY_INVALID:-0}" == 1 ]]; then
      print '{"recovered":false,"integrityValid":false}'
    else
      print '{"recovered":false,"integrityValid":true,"version":"v1.5.59"}'
    fi
    ;;
  auto)
    [[ "${CHATGPT_REMOTE_UPDATE_TRANSPORT:-}" == git ]]
    case "${MOCK_PRELAUNCH_RESULT:-current}" in
      current) print '{"updated":false,"method":"verified-git","latestVersion":"v1.5.59"}' ;;
      updated) print 'mock update progress'; print '{"updated":true,"method":"verified-git","version":"v1.5.59"}' ;;
      invalid-method) print '{"updated":true,"method":"verified-release","version":"v1.5.59"}' ;;
      fail) print -u2 'mock transport failure'; exit 7 ;;
      *) exit 8 ;;
    esac
    ;;
  *) exit 9 ;;
esac
MOCK_UPDATER
chmod 700 "$updater"
export MOCK_CALL_LOG="$temporary/prelaunch-calls.log"

skip_prelaunch_update_once=0
skip_update_check_once=0
prelaunch_updated=0
export MOCK_PRELAUNCH_RESULT=current MOCK_RECOVERY_INVALID=0
prelaunch_update "$node_bin" > "$temporary/prelaunch-current.out"
current_output="$(<"$temporary/prelaunch-current.out")"
[[ "$prelaunch_updated" == 0 && "$skip_update_check_once" == 1 && "$current_output" == *"outcome=current"* ]] \
  || { print -u2 "Current prelaunch proof was not accepted safely."; exit 1; }

skip_update_check_once=0
prelaunch_updated=0
export MOCK_PRELAUNCH_RESULT=updated
prelaunch_update "$node_bin" > "$temporary/prelaunch-updated.out"
updated_output="$(<"$temporary/prelaunch-updated.out")"
[[ "$prelaunch_updated" == 1 && "$skip_update_check_once" == 1 && "$updated_output" == *"outcome=updated"* ]] \
  || { print -u2 "Verified Git prelaunch update proof was not accepted."; exit 1; }
[[ "$(tail -n 2 "$MOCK_CALL_LOG" | tr '\n' ' ')" == "auto recover " ]] \
  || { print -u2 "Updated prelaunch did not run recovery after apply."; exit 1; }

skip_update_check_once=0
prelaunch_updated=0
export MOCK_PRELAUNCH_RESULT=invalid-method
prelaunch_update "$node_bin" > "$temporary/prelaunch-invalid-method.out"
invalid_method_output="$(<"$temporary/prelaunch-invalid-method.out")"
[[ "$prelaunch_updated" == 0 && "$invalid_method_output" == *"bestEffortFailure="* ]] \
  || { print -u2 "Unverified prelaunch method was accepted."; exit 1; }

skip_update_check_once=0
prelaunch_updated=0
export MOCK_PRELAUNCH_RESULT=fail MOCK_RECOVERY_INVALID=1
if prelaunch_update "$node_bin" >/dev/null 2>&1; then
  print -u2 "Prelaunch failure continued without integrity-valid recovery."
  exit 1
fi
export MOCK_RECOVERY_INVALID=0

launch_guard="$temporary/launch.lock"
launch_guard_token="$$-$EPOCHSECONDS-123-launch"
inherited_launch_guard_token="$launch_guard_token"
launch_guard_owned=0
mkdir "$launch_guard"
print -rn -- "$launch_guard_token" > "$launch_guard/owner"
CHATGPT_REMOTE_LAUNCH_GUARD_HELD=1 acquire_launch_guard
[[ "$launch_guard_owned" == 1 ]] || { print -u2 "Updated launcher did not inherit the held launch guard."; exit 1; }
release_launch_guard
[[ ! -e "$launch_guard" ]] || { print -u2 "Inherited launch guard was not released by its owner."; exit 1; }

print -r -- '{"AppleScriptEscapeSemantic":true,"SharedEscapeHelper":true,"MacOSShellSyntax":true,"RelativeInvocation":true,"TransactionApply":true,"PrelaunchCurrentProof":true,"PrelaunchVerifiedUpdate":true,"PrelaunchMethodRejected":true,"PrelaunchRecoveryFailClosed":true,"InheritedLaunchGuard":true}'
