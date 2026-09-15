#!/bin/zsh
set -euo pipefail
zmodload zsh/datetime

root="${0:A:h:h}"
shortcut="$root/macos/MacOSShortcut.sh"
process_guard="$root/macos/AppProcessGuard.sh"
startup_progress="$root/macos/StartupProgress.js"
update_platform="$root/macos/UpdateSessionPlatform.sh"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-remote-macos-support.XXXXXX")"
temporary="${temporary:A}"
fixture_pids=()
cleanup() {
  local fixture_pid
  for fixture_pid in "${fixture_pids[@]}"; do
    kill -TERM "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  done
  rm -rf -- "$temporary"
}
trap cleanup EXIT INT TERM

[[ -f "$startup_progress" ]] || { print -u2 'The native startup progress helper is missing.'; exit 1; }
for progress_contract in NSWindow NSProgressIndicator NSTimer.scheduledTimerWithTimeIntervalRepeatsBlock update-recovery update-check renderer-readiness; do
  /usr/bin/grep -F "$progress_contract" "$startup_progress" >/dev/null || { print -u2 "Native startup progress contract is missing: $progress_contract"; exit 1; }
done
if /usr/bin/grep -E 'NSRunningApplication|terminate\(\)|do shell script|kill -9|killall|pkill' "$update_platform" >/dev/null; then
  print -u2 'The macOS close path still contains a TCC-sensitive or force-kill operation.'
  exit 1
fi

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

process_fixture="$temporary/processes.txt"
cat > "$process_fixture" <<'PROCESSES'
101 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
102 /Applications/Codex.app/Contents/MacOS/Codex --remote-debugging-port=9229
103 /bin/zsh /fixture/AppProcessGuard.sh running /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
104 /Applications/ChatGPT.app/Contents/Frameworks/ChatGPT Helper.app/Contents/MacOS/ChatGPT Helper --parent=/Applications/ChatGPT.app/Contents/MacOS/ChatGPT
105 /Applications/Custom Client.app/Contents/MacOS/Custom Client --fixture
PROCESSES
exact_matches="$(/bin/zsh "$process_guard" match-stdin \
  --executable '/Applications/ChatGPT.app/Contents/MacOS/ChatGPT' \
  --executable '/Applications/Codex.app/Contents/MacOS/Codex' < "$process_fixture")"
[[ "$exact_matches" == *$'101\t/Applications/ChatGPT.app/Contents/MacOS/ChatGPT'* ]]
[[ "$exact_matches" == *$'102\t/Applications/Codex.app/Contents/MacOS/Codex --remote-debugging-port=9229'* ]]
[[ "$exact_matches" != *$'103\t'* && "$exact_matches" != *$'104\t'* ]] || {
  print -u2 'The exact process guard matched its helper or an unrelated child process.'
  exit 1
}
custom_match="$(/bin/zsh "$process_guard" match-stdin --executable '/Applications/Custom Client.app/Contents/MacOS/Custom Client' < "$process_fixture")"
[[ "$custom_match" == *$'105\t/Applications/Custom Client.app/Contents/MacOS/Custom Client --fixture'* ]]
legacy_process_name='Electron'
! print -r -- "$legacy_process_name" | /usr/bin/grep -Fx ChatGPT >/dev/null
[[ "$exact_matches" == *$'101\t'* ]] || { print -u2 'The command-path detector did not recover the app missed by the legacy name probe.'; exit 1; }
HOME="$temporary/home" /bin/zsh "$process_guard" running --process-list-file "$process_fixture" \
  --executable '/Applications/ChatGPT.app/Contents/MacOS/ChatGPT'
empty_process_fixture="$temporary/empty-processes.txt"
: > "$empty_process_fixture"
empty_status=0
HOME="$temporary/home" /bin/zsh "$process_guard" running --process-list-file "$empty_process_fixture" \
  --executable '/Applications/ChatGPT.app/Contents/MacOS/ChatGPT' || empty_status=$?
[[ "$empty_status" == 1 ]] || { print -u2 'A successful zero-match scan did not return the reserved stopped status.'; exit 1; }
failure_status=0
HOME="$temporary/home" /bin/zsh "$process_guard" running --process-list-file "$temporary/missing-processes.txt" \
  --executable '/Applications/ChatGPT.app/Contents/MacOS/ChatGPT' 2>/dev/null || failure_status=$?
[[ "$failure_status" == 2 ]] || { print -u2 'A failed process enumeration was confused with a stopped application.'; exit 1; }

mkdir -p "$temporary/home"
mkdir -p "$temporary/home/Applications/ChatGPT Mobile Projects.app" "$temporary/home/Library/Application Support/CodexRemoteFeatures/launchers"
print -r -- 'set launcherPath to "/obsolete/ChatGPT-Remote-Enabler-macOS-arm64-v1.5.1/MobileProjectView-macOS-arm64.sh"' \
  > "$temporary/home/Library/Application Support/CodexRemoteFeatures/launchers/ChatGPT Mobile Projects.applescript"
shortcut_install="$(HOME="$temporary/home" /bin/zsh "$shortcut" install)"
[[ "$shortcut_install" == *"Shortcut is valid:"* ]]
HOME="$temporary/home" /bin/zsh "$shortcut" probe >/dev/null
[[ -f "$temporary/home/Library/Application Support/CodexRemoteFeatures/launchers/ChatGPT Remote Enabler.applescript" ]]
[[ -d "$temporary/home/Applications/ChatGPT Remote Enabler.app" ]]
legacy_source="$temporary/home/Library/Application Support/CodexRemoteFeatures/launchers/ChatGPT Mobile Projects.applescript"
[[ -d "$temporary/home/Applications/ChatGPT Mobile Projects.app" && -f "$legacy_source" ]]
/usr/bin/grep -F "set launcherPath to \"$root/macos/MobileProjectView-macOS-arm64.sh\"" "$legacy_source" >/dev/null
! /usr/bin/grep -F 'v1.5.1' "$legacy_source" >/dev/null
relative_probe="$(cd "$root/macos" && HOME="$temporary/home" /bin/zsh ./Update-ChatGPTRemote.sh probe)"
[[ "$relative_probe" == *"\"installRoot\":\"$root/macos\""* ]] || {
  print -u2 "Relative updater invocation resolved against HOME instead of its original working directory."
  exit 1
}

node_bin="$(command -v node)"
"$node_bin" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 && typeof WebSocket === "function" ? 0 : 1)' \
  || { print -u2 "Test-MacOSSupport.zsh requires Node.js 22 or newer with built-in WebSocket support."; exit 1; }
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
for function_name in release_launch_guard acquire_launch_guard last_json_result recover_update prelaunch_update continue_with_updated_launcher; do
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
      print '{"recovered":false,"integrityValid":false,"version":"v1.5.59"}'
    elif [[ "${MOCK_RECOVERY_CHANGED:-0}" == 1 ]]; then
      print '{"recovered":true,"integrityValid":true,"version":"v1.5.59","recoveryMode":"complete-forward"}'
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
      current-missing-method) print '{"updated":false,"latestVersion":"v1.5.59"}' ;;
      current-invalid-method) print '{"updated":false,"method":"verified-release","latestVersion":"v1.5.59"}' ;;
      trailing-noise) print '{"updated":false,"method":"verified-git","latestVersion":"v1.5.59"}'; print 'trailing noise' ;;
      multiple-json) print '{"phase":"prepared"}'; print '{"updated":false,"method":"verified-git","latestVersion":"v1.5.59"}' ;;
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
recovery_changed=0
export MOCK_PRELAUNCH_RESULT=current MOCK_RECOVERY_INVALID=0 MOCK_RECOVERY_CHANGED=0
prelaunch_update "$node_bin" > "$temporary/prelaunch-current.out"
current_output="$(<"$temporary/prelaunch-current.out")"
[[ "$prelaunch_updated" == 0 && "$skip_update_check_once" == 1 && "$current_output" == *"outcome=current"* ]] \
  || { print -u2 "Current prelaunch proof was not accepted safely."; exit 1; }

skip_update_check_once=0
prelaunch_updated=0
recovery_changed=0
export MOCK_RECOVERY_CHANGED=1 MOCK_PRELAUNCH_RESULT=current
recover_update "$node_bin" > "$temporary/recovery-forward.out"
prelaunch_update "$node_bin" > "$temporary/prelaunch-after-recovery.out"
[[ "$prelaunch_updated" == 1 && "$recovery_changed" == 1 && "$skip_update_check_once" == 1 ]] \
  || { print -u2 "Recovered files with a current Git result did not require updated-entry-point handoff."; exit 1; }
if CODEX_REMOTE_RECOVERY_CONTINUATION=1 recover_update "$node_bin" >/dev/null 2>&1; then
  print -u2 "Repeated recovery was allowed to loop through another handoff."
  exit 1
fi
export MOCK_RECOVERY_CHANGED=0

skip_update_check_once=0
prelaunch_updated=0
recovery_changed=0
export MOCK_PRELAUNCH_RESULT=updated
prelaunch_update "$node_bin" > "$temporary/prelaunch-updated.out"
updated_output="$(<"$temporary/prelaunch-updated.out")"
[[ "$prelaunch_updated" == 1 && "$skip_update_check_once" == 1 && "$updated_output" == *"outcome=updated"* ]] \
  || { print -u2 "Verified Git prelaunch update proof was not accepted."; exit 1; }
[[ "$(tail -n 2 "$MOCK_CALL_LOG" | tr '\n' ' ')" == "auto recover " ]] \
  || { print -u2 "Updated prelaunch did not run recovery after apply."; exit 1; }

skip_update_check_once=0
prelaunch_updated=0
recovery_changed=0
export MOCK_PRELAUNCH_RESULT=invalid-method
prelaunch_update "$node_bin" > "$temporary/prelaunch-invalid-method.out"
invalid_method_output="$(<"$temporary/prelaunch-invalid-method.out")"
[[ "$prelaunch_updated" == 0 && "$invalid_method_output" == *"bestEffortFailure="* ]] \
  || { print -u2 "Unverified prelaunch method was accepted."; exit 1; }

for invalid_result in current-missing-method current-invalid-method trailing-noise multiple-json; do
  skip_update_check_once=0
  prelaunch_updated=0
  recovery_changed=0
  export MOCK_PRELAUNCH_RESULT="$invalid_result"
  prelaunch_update "$node_bin" > "$temporary/prelaunch-${invalid_result}.out"
  invalid_output="$(<"$temporary/prelaunch-${invalid_result}.out")"
  [[ "$prelaunch_updated" == 0 && "$skip_update_check_once" == 0 && "$invalid_output" == *"bestEffortFailure="* ]] \
    || { print -u2 "Invalid prelaunch proof was accepted: $invalid_result"; exit 1; }
done

skip_update_check_once=0
prelaunch_updated=0
recovery_changed=0
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

handoff_launcher="$temporary/source-checkout-handoff.zsh"
cat > "$handoff_launcher" <<'HANDOFF_LAUNCHER'
#!/bin/zsh
set -euo pipefail
[[ "${1:-}" == enable ]]
[[ "${CHATGPT_REMOTE_LAUNCH_GUARD_HELD:-0}" == 1 ]]
[[ "${CODEX_REMOTE_SKIP_PRELAUNCH_UPDATE_ONCE:-0}" == 1 ]]
[[ "${CODEX_REMOTE_SKIP_UPDATE_CHECK_ONCE:-0}" == 1 ]]
[[ "${CODEX_REMOTE_RECOVERY_CONTINUATION:-0}" == 1 ]]
print -r -- '{"sourceCheckoutInterpreterHandoff":true,"recoveryContinuation":true}'
HANDOFF_LAUNCHER
chmod 644 "$handoff_launcher"
script_path="$handoff_launcher"
action=enable
use_proxy=0
launch_guard_token="$-$EPOCHSECONDS-456-launch"
prelaunch_updated=1
recovery_changed=1
handoff_output="$(continue_with_updated_launcher)"
[[ "$handoff_output" == *'"sourceCheckoutInterpreterHandoff":true'* && "$handoff_output" == *'"recoveryContinuation":true'* ]] \
  || { print -u2 "The updated source-checkout launcher was not handed off through zsh."; exit 1; }

# Exercise the permission-free close path against a copied harmless executable,
# never against ChatGPT or Codex.  The first case proves one exact identity can
# receive a single graceful TERM fallback; the second proves a changed start
# token is rejected and receives no signal.
fake_app="$temporary/Fake ChatGPT.app"
fake_executable="$fake_app/Contents/MacOS/ChatGPT"
mkdir -p "$fake_app/Contents/MacOS"
ln -s /bin/sleep "$fake_executable"
cat > "$fake_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ChatGPT</string>
<key>CFBundleIdentifier</key><string>com.example.fixture-chatgpt</string>
</dict></plist>
PLIST
"$fake_executable" 120 &
fixture_pid=$!
fixture_pids+=("$fixture_pid")
sleep 0.2
fixture_start="$(/bin/ps -p "$fixture_pid" -o lstart= | /usr/bin/awk '{$1=$1; print}')"
fixture_uid="$(/usr/bin/id -u)"
fixture_config="$temporary/close-fixture.json"
cat > "$fixture_config" <<EOF
{"schemaVersion":1,"platform":"darwin","app":{"pid":$fixture_pid,"startToken":"$fixture_start","executablePath":"$fake_executable","appPath":"$fake_app","bundleId":"com.example.fixture-chatgpt"},"rendererPort":9229}
EOF
close_fixture_output="$(/bin/zsh "$update_platform" close "$fixture_config" /bin/false)"
[[ "$close_fixture_output" == *'"closed":true'* && "$close_fixture_output" == *'"method":"POSIX_SIGTERM"'* ]] \
  || { print -u2 "Exact fixture graceful close did not use one POSIX TERM fallback: $close_fixture_output"; exit 1; }
if /bin/kill -0 "$fixture_pid" 2>/dev/null; then
  print -u2 'The exact fixture process survived its graceful TERM request.'
  exit 1
fi
fixture_pids=()

"$fake_executable" 120 &
fixture_pid=$!
fixture_pids+=("$fixture_pid")
sleep 0.2
fixture_start="$(/bin/ps -p "$fixture_pid" -o lstart= | /usr/bin/awk '{$1=$1; print}')"
cat > "$fixture_config" <<EOF
{"schemaVersion":1,"platform":"darwin","app":{"pid":$fixture_pid,"startToken":"$fixture_start-mismatch","executablePath":"$fake_executable","appPath":"$fake_app","bundleId":"com.example.fixture-chatgpt"},"rendererPort":9229}
EOF
if /bin/zsh "$update_platform" close "$fixture_config" /bin/false >/dev/null 2>&1; then
  print -u2 'A changed fixture start token was accepted for graceful close.'
  exit 1
fi
if ! /bin/kill -0 "$fixture_pid" 2>/dev/null; then
  print -u2 'A mismatched fixture identity was signaled.'
  exit 1
fi
kill -TERM "$fixture_pid" 2>/dev/null || true
wait "$fixture_pid" 2>/dev/null || true
fixture_pids=()

print -r -- '{"AppleScriptEscapeSemantic":true,"SharedEscapeHelper":true,"ExactExecutableProcessGuard":true,"LegacyNameProbeMissCovered":true,"NoHelperOrUnrelatedMatches":true,"CustomAppNamePath":true,"EnumerationFailureFailClosed":true,"ShortcutAtomicInstall":true,"LegacyShortcutMigrated":true,"MacOSShellSyntax":true,"RelativeInvocation":true,"TransactionApply":true,"PrelaunchCurrentProof":true,"RecoveredCurrentHandoff":true,"RepeatedRecoveryRejected":true,"PrelaunchVerifiedUpdate":true,"PrelaunchMethodRejected":true,"PrelaunchStrictFinalJsonProof":true,"PrelaunchCurrentMethodRequired":true,"PrelaunchRecoveryFailClosed":true,"InheritedLaunchGuard":true,"SourceCheckoutInterpreterHandoff":true,"MacOSNativeStartupProgress":true,"MacOSPermissionFreeGracefulClose":true,"MacOSCloseFixtureExactIdentity":true,"MacOSCloseFixtureMismatchRejected":true}'
