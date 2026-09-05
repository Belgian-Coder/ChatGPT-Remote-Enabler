#!/bin/zsh
set -euo pipefail

action="${1:-check}"
action="${action:l}"
(( $# > 0 )) && shift
target_version=""
expected_archive_sha256=""
prepared_directory=""
lock_timeout_seconds=120
launch_lock_held=0
while (( $# > 0 )); do
  case "$1" in
    --target-version) (( $# >= 2 )) || { print -u2 'Missing --target-version value.'; exit 2; }; target_version="$2"; shift 2 ;;
    --expected-archive-sha256) (( $# >= 2 )) || { print -u2 'Missing --expected-archive-sha256 value.'; exit 2; }; expected_archive_sha256="${2:l}"; shift 2 ;;
    --prepared-directory) (( $# >= 2 )) || { print -u2 'Missing --prepared-directory value.'; exit 2; }; prepared_directory="$2"; shift 2 ;;
    --lock-timeout-seconds) (( $# >= 2 )) || { print -u2 'Missing --lock-timeout-seconds value.'; exit 2; }; lock_timeout_seconds="$2"; shift 2 ;;
    --launch-lock-held) launch_lock_held=1; shift ;;
    *) print -u2 "Unknown updater argument: $1"; exit 2 ;;
  esac
done
script_path="${0:A}"
[[ -n "${HOME:-}" && -d "$HOME" ]] || { print -u2 "A readable user home directory is required."; exit 2; }
cd -- "$HOME" || { print -u2 "Could not enter the user home directory."; exit 2; }
install_root="${CHATGPT_REMOTE_UPDATE_INSTALL_ROOT:-${script_path:h}}"
install_root="${install_root:A}"
repository="${CHATGPT_REMOTE_UPDATE_REPOSITORY:-Belgian-Coder/ChatGPT-Remote-Enabler}"
api_base="${CHATGPT_REMOTE_UPDATE_API_BASE:-https://api.github.com}"
latest_url="${CHATGPT_REMOTE_UPDATE_LATEST_URL:-}"
check_interval_hours="${CHATGPT_REMOTE_UPDATE_INTERVAL_HOURS:-0}"
platform_name="macOS-arm64"
state_root="$HOME/Library/Application Support/ChatGPTRemoteEnabler/update"
disabled_marker="$state_root/auto-update-disabled"
last_check="$state_root/last-check.json"
rollback_root="$state_root/rollback"
lock_dir="$state_root/update.lock"
lock_owner="$lock_dir/owner"
lock_token="$$-$(date +%s)-$RANDOM"
launch_lock_dir="${state_root:h}/launch.lock"
launch_lock_owner="$launch_lock_dir/owner"
launch_lock_token="$$-$(date +%s)-$RANDOM-launch"
transaction_journal="$state_root/transaction.json"
transaction_helper="${script_path:h}/update-transaction.js"
lock_acquired=0
launch_lock_acquired=0
temporary_root=""
temporary_staging=""

cleanup() {
  local current_owner="" current_launch_owner=""
  if [[ -n "$temporary_root" && "$temporary_root" == "${TMPDIR:-/tmp}"/* && -d "$temporary_root" ]]; then
    rm -rf -- "$temporary_root"
  fi
  if [[ -n "$temporary_staging" && "$temporary_staging" == *.prepare-<->-* && -d "$temporary_staging" ]]; then
    rm -rf -- "$temporary_staging"
  fi
  [[ -f "$lock_owner" ]] && current_owner="$(<"$lock_owner")"
  if (( lock_acquired )) && [[ -d "$lock_dir" ]] && [[ "$current_owner" == "$lock_token" ]]; then
    rm -f -- "$lock_owner"
    rmdir "$lock_dir" 2>/dev/null || true
  fi
  [[ -f "$launch_lock_owner" ]] && current_launch_owner="$(<"$launch_lock_owner")"
  if (( launch_lock_acquired )) && [[ -d "$launch_lock_dir" ]] && [[ "$current_launch_owner" == "$launch_lock_token" ]]; then
    rm -f -- "$launch_lock_owner"
    rmdir "$launch_lock_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

resolve_node() {
  local candidates=(
    "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"
    "$HOME/Library/Application Support/ChatGPTRemoteEnabler/node/bin/node"
    "/opt/homebrew/bin/node"
    "/usr/local/bin/node"
    "$(command -v node 2>/dev/null || true)"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]] &&
       "$candidate" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 && typeof WebSocket === "function" ? 0 : 1)' >/dev/null 2>&1; then
      print -r -- "$candidate"
      return 0
    fi
  done
  print -u2 "Node.js was not found for release metadata validation."
  return 1
}

assert_https_url() {
  local url="$1"
  if [[ "$url" == https://* ]]; then return 0; fi
  if [[ "${CHATGPT_REMOTE_UPDATE_ALLOW_INSECURE:-0}" == "1" && "$url" == http://127.0.0.1:* ]]; then return 0; fi
  print -u2 "Update URL must use HTTPS: $url"
  return 1
}

release_url() {
  local requested_tag="${1:-}"
  if [[ -n "$latest_url" ]]; then
    assert_https_url "$latest_url"
    print -r -- "$latest_url"
    return
  fi
  if [[ "$repository" != */* || "$repository" == */*/* || "$repository" == *[^A-Za-z0-9_./-]* ]]; then
    print -u2 "Repository must use owner/name form."
    return 1
  fi
  api_base="${api_base%/}"
  assert_https_url "$api_base"
  if [[ -n "$requested_tag" ]]; then
    [[ "$requested_tag" =~ '^v[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$' ]] || { print -u2 "Invalid release tag: $requested_tag"; return 1; }
    print -r -- "$api_base/repos/$repository/releases/tags/$requested_tag"
  else
    print -r -- "$api_base/repos/$repository/releases/latest"
  fi
}

local_version() {
  if [[ -f "$install_root/VERSION" ]]; then
    local value="$(<"$install_root/VERSION")"
    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    print -r -- "${value:-v0.0.0}"
  else
    print -r -- "v0.0.0"
  fi
}

auto_disabled() {
  case "${CHATGPT_REMOTE_AUTO_UPDATE:-1}" in
    0|false|FALSE|off|OFF|no|NO) return 0 ;;
  esac
  [[ -f "$disabled_marker" ]]
}

check_due() {
  [[ "$check_interval_hours" == <-> ]] || { print -u2 "CHATGPT_REMOTE_UPDATE_INTERVAL_HOURS must be a non-negative integer."; return 1; }
  (( check_interval_hours == 0 )) && return 0
  [[ -f "$last_check" ]] || return 0
  local modified now
  modified="$(/usr/bin/stat -f %m "$last_check")"
  now="$(date +%s)"
  (( now - modified >= check_interval_hours * 3600 ))
}

probe() {
  local enabled=true
  auto_disabled && enabled=false
  print -r -- "{\"autoUpdateEnabled\":$enabled,\"checkIntervalHours\":$check_interval_hours,\"installRoot\":\"${install_root//\\/\\\\}\",\"latestReleaseUrl\":\"$(release_url)\",\"localVersion\":\"$(local_version)\",\"repository\":\"$repository\"}"
}

record_check() {
  local tag="$1" temporary_check="$state_root/last-check.json.tmp.$$"
  mkdir -p "$state_root"
  print -r -- "{\"checkedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"repository\":\"$repository\",\"tag\":\"$tag\"}" > "$temporary_check"
  mv -f -- "$temporary_check" "$last_check"
}

acquire_lock() {
  mkdir -p "$state_root"
  [[ "$lock_timeout_seconds" == <-> && "$lock_timeout_seconds" -ge 1 && "$lock_timeout_seconds" -le 600 ]] || {
    print -u2 '--lock-timeout-seconds must be between 1 and 600.'; return 1;
  }
  local deadline=$(( $(date +%s) + lock_timeout_seconds )) owner owner_pid
  while true; do
    if mkdir "$lock_dir" 2>/dev/null; then
      print -rn -- "$lock_token" > "$lock_owner"
      lock_acquired=1
      return 0
    fi
    if [[ -f "$lock_owner" ]]; then
      owner="$(<"$lock_owner")"
      owner_pid="${owner%%-*}"
      if [[ "$owner_pid" == <-> ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -f -- "$lock_owner"
        rmdir "$lock_dir" 2>/dev/null || true
        continue
      fi
    elif [[ -d "$lock_dir" ]]; then
      local modified="$(/usr/bin/stat -f %m "$lock_dir" 2>/dev/null || print 0)"
      if (( modified > 0 && $(date +%s) - modified > 1800 )); then rmdir "$lock_dir" 2>/dev/null || true; continue; fi
    fi
    (( $(date +%s) >= deadline )) && { print -u2 "UPDATE_BUSY: another updater still owns the lock after $lock_timeout_seconds seconds."; return 1; }
    sleep 0.1
  done
}

acquire_launch_guard() {
  mkdir -p "${launch_lock_dir:h}"
  local deadline=$(( $(date +%s) + lock_timeout_seconds )) owner owner_pid
  while true; do
    if mkdir "$launch_lock_dir" 2>/dev/null; then
      print -rn -- "$launch_lock_token" > "$launch_lock_owner"
      launch_lock_acquired=1
      return 0
    fi
    if [[ -f "$launch_lock_owner" ]]; then
      owner="$(<"$launch_lock_owner")"
      owner_pid="${owner%%-*}"
      if [[ "$owner_pid" == <-> ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -f -- "$launch_lock_owner"
        rmdir "$launch_lock_dir" 2>/dev/null || true
        continue
      fi
    elif [[ -d "$launch_lock_dir" ]]; then
      local modified="$(/usr/bin/stat -f %m "$launch_lock_dir" 2>/dev/null || print 0)"
      if (( modified > 0 && $(date +%s) - modified > 1800 )); then rmdir "$launch_lock_dir" 2>/dev/null || true; continue; fi
    fi
    (( $(date +%s) >= deadline )) && { print -u2 "UPDATE_BUSY: launcher injection still owns the launch guard after $lock_timeout_seconds seconds."; return 1; }
    sleep 0.1
  done
}

download_release_metadata() {
  local node_bin="$1" metadata_path="$2" requested_tag="${3:-}"
  local url="$(release_url "$requested_tag")"
  local -a protocol_args=(--proto '=https' --proto-redir '=https')
  [[ "$url" == http://127.0.0.1:* ]] && protocol_args=(--proto '=http' --proto-redir '=http')
  /usr/bin/curl "${protocol_args[@]}" --fail --location --silent --show-error --max-time 20 \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: ChatGPT-Remote-Enabler-Updater' \
    "$url" -o "$metadata_path"
  "$node_bin" -e '
    const fs = require("node:fs");
    const release = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const platform = process.argv[2];
    const tag = String(release.tag_name || "");
    if (release.draft || release.prerelease) throw new Error("Latest endpoint returned a draft or prerelease");
    if (!/^v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/.test(tag)) throw new Error(`Invalid release tag: ${tag}`);
    const archiveName = `ChatGPT-Remote-Enabler-${platform}-${tag}.zip`;
    const sumsName = `SHA256SUMS-${tag}.txt`;
    const archive = (release.assets || []).find((asset) => asset.name === archiveName);
    const sums = (release.assets || []).find((asset) => asset.name === sumsName);
    if (!archive || !sums) throw new Error(`Release ${tag} is missing required assets`);
    if (process.argv[3] && tag !== process.argv[3]) throw new Error(`Pinned release ${process.argv[3]} resolved to ${tag}`);
    process.stdout.write([tag, archiveName, archive.browser_download_url, sumsName, sums.browser_download_url, archive.digest || ""].join("\t"));
  ' "$metadata_path" "$platform_name" "$requested_tag"
}

download_file() {
  local url="$1" destination="$2" maximum_seconds="$3"
  local -a protocol_args=(--proto '=https' --proto-redir '=https')
  [[ "$url" == http://127.0.0.1:* && "${CHATGPT_REMOTE_UPDATE_ALLOW_INSECURE:-0}" == 1 ]] && protocol_args=(--proto '=http' --proto-redir '=http')
  /usr/bin/curl "${protocol_args[@]}" --fail --location --silent --show-error --max-time "$maximum_seconds" "$url" -o "$destination"
}

published_archive_hash() {
  local archive_name="$1" sums_name="$2" sums_url="$3" asset_digest="$4"
  if [[ "$asset_digest" =~ '^sha256:([0-9a-fA-F]{64})$' ]]; then
    print -r -- "${match[1]:l}"
    return 0
  fi
  local sums_path="$temporary_root/$sums_name" expected
  download_file "$sums_url" "$sums_path" 30
  expected="$(tr -d '\r' < "$sums_path" | /usr/bin/awk -v name="$archive_name" '$2 == name || $2 == "*" name { print $1; exit }')"
  [[ ${#expected} -eq 64 && "$expected" != *[^0-9a-fA-F]* ]] || { print -u2 "Published checksum for $archive_name is missing."; return 1; }
  print -r -- "${expected:l}"
}

assert_pinned_arguments() {
  [[ "$target_version" =~ '^v[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$' ]] || { print -u2 'Target version must be an exact vMAJOR.MINOR.PATCH release tag.'; return 1; }
  [[ ${#expected_archive_sha256} -eq 64 && "$expected_archive_sha256" != *[^0-9a-f]* ]] || { print -u2 'Expected archive SHA-256 must contain 64 hexadecimal characters.'; return 1; }
  [[ -n "$prepared_directory" ]] || { print -u2 'Prepared directory is required.'; return 1; }
}

invoke_transaction_helper() {
  local operation="$1"
  shift
  [[ -f "$transaction_helper" && ! -L "$transaction_helper" ]] || { print -u2 "Transactional update helper is missing: $transaction_helper"; return 1; }
  local node_bin="$(resolve_node)" output
  if ! output="$("$node_bin" "$transaction_helper" "$operation" "$@" 2>&1)"; then
    if [[ "$output" == *UNSAFE_MIXED_INSTALL* || "$output" == *UPDATE_BUSY* ]]; then print -u2 -- "$output"
    else print -u2 "Transactional update helper failed during $operation: $output"
    fi
    return 1
  fi
  print -r -- "$output"
}

assert_safe_prepared_directory() {
  local requested="$1" resolved_path="${1:A}" install_prefix="${install_root%/}/" prepared_prefix
  prepared_prefix="${resolved_path%/}/"
  [[ "$resolved_path" != "$install_root" && "$resolved_path" != "$install_prefix"* && "$install_root" != "$prepared_prefix"* ]] || {
    print -u2 'Prepared directory must be separate from the install root.'; return 1;
  }
  [[ "$resolved_path" != / && -n "${resolved_path:t}" ]] || { print -u2 'Prepared directory cannot be a filesystem root.'; return 1; }
  local parent="${resolved_path:h}" current="/" component
  mkdir -p "$parent"
  for component in ${(s:/:)${parent#/}}; do
    current="${current%/}/$component"
    [[ ! -L "$current" ]] || { print -u2 "Prepared directory traverses a symbolic link: $resolved_path"; return 1; }
  done
  [[ ! -e "$resolved_path" || ( -d "$resolved_path" && ! -L "$resolved_path" ) ]] || { print -u2 'Prepared directory exists and is not a real directory.'; return 1; }
  print -r -- "$resolved_path"
}

prepare_release() {
  local requested_version="$1" expected_hash="$2" requested_destination="$3"
  local destination="$(assert_safe_prepared_directory "$requested_destination")"
  local -a helper_args=(--prepared-root "$destination" --platform "$platform_name" --version "$requested_version" --archive-sha256 "$expected_hash")
  if [[ -d "$destination" ]]; then
    invoke_transaction_helper validate-prepared "${helper_args[@]}"
    return
  fi
  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-remote-prepare.XXXXXX")"
  local metadata="$temporary_root/release.json" values tag archive_name archive_url sums_name sums_url asset_digest published_hash archive_path
  values="$(download_release_metadata "$(resolve_node)" "$metadata" "$requested_version")"
  IFS=$'\t' read -r tag archive_name archive_url sums_name sums_url asset_digest <<< "$values"
  published_hash="$(published_archive_hash "$archive_name" "$sums_name" "$sums_url" "$asset_digest")"
  [[ "$published_hash" == "$expected_hash" ]] || { print -u2 "Pinned archive hash $expected_hash does not match published hash $published_hash."; return 1; }
  assert_https_url "$archive_url"
  archive_path="$temporary_root/$archive_name"
  download_file "$archive_url" "$archive_path" 120
  local actual="$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')"
  [[ "${actual:l}" == "$expected_hash" ]] || { print -u2 'Downloaded release archive failed its pinned SHA-256 verification.'; return 1; }
  local extract_root="$temporary_root/extract"
  mkdir -p "$extract_root"
  if [[ -x /usr/bin/ditto ]]; then /usr/bin/ditto -x -k "$archive_path" "$extract_root"
  elif command -v unzip >/dev/null 2>&1; then unzip -q "$archive_path" -d "$extract_root"
  else print -u2 'Neither ditto nor unzip is available to extract the release.'; return 1
  fi
  local release_root
  if [[ -f "$extract_root/VERSION" ]]; then release_root="$extract_root"
  else
    local roots=("$extract_root"/*(/N))
    (( ${#roots[@]} == 1 )) || { print -u2 'Release archive must be flat or contain one top-level directory.'; return 1; }
    release_root="${roots[1]}"
  fi
  local archive_version="$(<"$release_root/VERSION")"
  archive_version="${archive_version//$'\r'/}"; archive_version="${archive_version//$'\n'/}"
  [[ "$archive_version" == "$requested_version" ]] || { print -u2 'Prepared archive VERSION does not match pinned release.'; return 1; }
  temporary_staging="$destination.prepare-$$-$RANDOM"
  mkdir "$temporary_staging"
  /bin/cp -pR "$release_root"/. "$temporary_staging"/
  /bin/cp -p -- "$archive_path" "$temporary_staging/.chatgpt-remote-release.zip"
  invoke_transaction_helper seal-prepared --prepared-root "$temporary_staging" --platform "$platform_name" --version "$requested_version" --archive-sha256 "$expected_hash" >/dev/null
  if ! mv -- "$temporary_staging" "$destination" 2>/dev/null; then
    [[ -d "$destination" ]] || { print -u2 'Prepared update could not be committed atomically.'; return 1; }
  fi
  [[ "$temporary_staging" == "$destination" ]] || rm -rf -- "$temporary_staging" 2>/dev/null || true
  temporary_staging=""
  invoke_transaction_helper validate-prepared "${helper_args[@]}"
}

apply_prepared_release() {
  local requested_version="$1" expected_hash="$2" requested_source="$3"
  local source="$(assert_safe_prepared_directory "$requested_source")"
  local safe_version="${requested_version//[^A-Za-z0-9._-]/_}"
  local backup_base="$rollback_root/$(date +%Y%m%d-%H%M%S)-$safe_version" backup_root="$backup_base"
  mkdir -p "$rollback_root"
  if [[ -e "$backup_root" ]]; then backup_root="$(mktemp -d "$backup_base.XXXXXX")"; rmdir "$backup_root"; fi
  invoke_transaction_helper apply --install-root "$install_root" --prepared-root "$source" \
    --journal-path "$transaction_journal" --backup-root "$backup_root" --platform "$platform_name" \
    --version "$requested_version" --archive-sha256 "$expected_hash"
}

recover_pending_transaction() {
  local output
  if [[ ! -f "$transaction_journal" && "${install_root:t}" == macos && ( -d "${install_root:h}/.git" || -f "${install_root:h}/.git" ) ]]; then
    local git_bin="$(command -v git 2>/dev/null || true)" checkout_root=""
    [[ -n "$git_bin" ]] && checkout_root="$($git_bin -C "$install_root" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$checkout_root" && "${checkout_root:A}/macos" == "$install_root" ]]; then
      print -r -- "{\"recovered\":false,\"integrityValid\":true,\"version\":\"$(local_version)\",\"installKind\":\"git-checkout\"}"
      return 0
    fi
  fi
  if ! output="$(invoke_transaction_helper recover --journal-path "$transaction_journal" --install-root "$install_root" 2>&1)"; then
    [[ "$output" == *UNSAFE_MIXED_INSTALL* || "$output" == *UPDATE_BUSY* ]] || output="UNSAFE_MIXED_INSTALL: installed integrity or transaction recovery failed: $output"
    print -u2 -- "$output"
    return 1
  fi
  print -r -- "$output"
}

installed_integrity_valid() {
  local manifest="$install_root/RELEASE-MANIFEST.sha256" line hash relative file_path actual count=0
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"; hash="${line%% *}"; relative="${line#* \*}"
    [[ ${#hash} -eq 64 && "$hash" != *[^0-9a-fA-F]* && -n "$relative" && "$relative" != /* && "$relative" != *'../'* && "$relative" != '../'* && "$relative" != *'/..' ]] || return 1
    file_path="$install_root/$relative"
    [[ -f "$file_path" && ! -L "$file_path" ]] || return 1
    actual="$(/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk '{print $1}')"
    [[ "${actual:l}" == "${hash:l}" ]] || return 1
    (( count += 1 ))
  done < "$manifest"
  (( count > 0 ))
}

version_is_newer() {
  local node_bin="$1" latest="$2" current="$3"
  "$node_bin" -e '
    const parts = (value) => value.replace(/^v/, "").split(/[+-]/, 1)[0].split(".").map(Number);
    const a = parts(process.argv[1]), b = parts(process.argv[2]);
    for (let index = 0; index < 3; index += 1) {
      if (a[index] !== b[index]) process.exit(a[index] > b[index] ? 0 : 1);
    }
    process.exit(1);
  ' "$latest" "$current"
}

case "$action" in
  enable-auto-update)
    rm -f -- "$disabled_marker"
    probe
    exit 0
    ;;
  disable-auto-update)
    mkdir -p "$state_root"
    print 'disabled' > "$disabled_marker"
    probe
    exit 0
    ;;
  probe)
    probe
    exit 0
    ;;
  auto|check|update|prepare|apply-prepared|applyprepared|recover) ;;
  *) print -u2 "Usage: $0 {auto|check|update|prepare|apply-prepared|recover|enable-auto-update|disable-auto-update|probe}"; exit 2 ;;
esac

typeset read_only_action=0
[[ "$action" == check || "$action" == prepare ]] && read_only_action=1
if (( ! read_only_action && ! launch_lock_held )) && [[ "${CHATGPT_REMOTE_LAUNCH_GUARD_HELD:-0}" != 1 ]]; then
  acquire_launch_guard
fi
acquire_lock
typeset recovery_output='{"recovered":false,"integrityValid":true}'
if (( read_only_action )); then
  [[ ! -f "$transaction_journal" ]] || { print -u2 'UPDATE_RECOVERY_REQUIRED: a pending update transaction must be recovered before checking or preparing another release.'; exit 1; }
else
  recovery_output="$(recover_pending_transaction)"
fi
if [[ "$action" == recover ]]; then
  print -r -- "$recovery_output"
  exit 0
fi
if [[ "$action" == auto ]]; then
  if auto_disabled; then print '{"skipped":true,"reason":"auto-update-disabled"}'; exit 0; fi
  if ! check_due; then print '{"skipped":true,"reason":"check-interval"}'; exit 0; fi
fi
if [[ "$action" == prepare || "$action" == apply-prepared || "$action" == applyprepared ]]; then
  assert_pinned_arguments
  if [[ "$action" == prepare ]]; then
    prepare_release "$target_version" "$expected_archive_sha256" "$prepared_directory"
    exit 0
  fi
  typeset apply_output=""
  if ! apply_output="$(apply_prepared_release "$target_version" "$expected_archive_sha256" "$prepared_directory" 2>&1)"; then
    [[ "$apply_output" == *UNSAFE_MIXED_INSTALL* || "$apply_output" == *UPDATE_BUSY* ]] && print -u2 -- "$apply_output" || print -u2 -- "UPDATE_APPLY_FAILED: $apply_output"
    exit 1
  fi
  record_check "$target_version"
  print -r -- "$apply_output"
  exit 0
fi
typeset node_bin="$(resolve_node)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-remote-update.XXXXXX")"
typeset metadata="$temporary_root/release.json" values tag archive_name archive_url sums_name sums_url asset_digest published_hash
values="$(download_release_metadata "$node_bin" "$metadata")"
IFS=$'\t' read -r tag archive_name archive_url sums_name sums_url asset_digest <<< "$values"
published_hash="$(published_archive_hash "$archive_name" "$sums_name" "$sums_url" "$asset_digest")"
typeset current="$(local_version)" available=false
if version_is_newer "$node_bin" "$tag" "$current"; then available=true; fi
if [[ "$tag" == "$current" ]] && ! installed_integrity_valid; then available=true; fi
if [[ "$action" == check || "$available" == false ]]; then
  record_check "$tag"
  print -r -- "{\"available\":$available,\"latestVersion\":\"$tag\",\"localVersion\":\"$current\",\"archiveSha256\":\"$published_hash\",\"updated\":false,\"method\":\"verified-release\"}"
  exit 0
fi
rm -rf -- "$temporary_root"
temporary_root=""
typeset prepared_root="$state_root/prepared/${tag}-${published_hash[1,16]}"
prepare_release "$tag" "$published_hash" "$prepared_root" >/dev/null
typeset update_output=""
if ! update_output="$(apply_prepared_release "$tag" "$published_hash" "$prepared_root" 2>&1)"; then
  [[ "$update_output" == *UNSAFE_MIXED_INSTALL* || "$update_output" == *UPDATE_BUSY* ]] && print -u2 -- "$update_output" || print -u2 -- "UPDATE_APPLY_FAILED: $update_output"
  exit 1
fi
record_check "$tag"
[[ -f "$transaction_journal" ]] || rm -rf -- "$prepared_root"
print -r -- "$update_output"
