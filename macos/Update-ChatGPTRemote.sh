#!/bin/zsh
set -euo pipefail

action="${1:-check}"
action="${action:l}"
script_path="${0:A}"
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
lock_acquired=0
temporary_root=""

cleanup() {
  if [[ -n "$temporary_root" && "$temporary_root" == "${TMPDIR:-/tmp}"/* && -d "$temporary_root" ]]; then
    rm -rf -- "$temporary_root"
  fi
  if (( lock_acquired )) && [[ -d "$lock_dir" ]]; then rmdir "$lock_dir" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

resolve_node() {
  local candidates=(
    "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"
    "/opt/homebrew/bin/node"
    "/usr/local/bin/node"
    "$(command -v node 2>/dev/null || true)"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then print -r -- "$candidate"; return 0; fi
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
  print -r -- "$api_base/repos/$repository/releases/latest"
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

acquire_lock() {
  mkdir -p "$state_root"
  if mkdir "$lock_dir" 2>/dev/null; then lock_acquired=1; return 0; fi
  if [[ -d "$lock_dir" ]]; then
    local modified now
    modified="$(/usr/bin/stat -f %m "$lock_dir" 2>/dev/null || print 0)"
    now="$(date +%s)"
    if (( modified > 0 && now - modified > 1800 )); then
      rmdir "$lock_dir" 2>/dev/null || true
      if mkdir "$lock_dir" 2>/dev/null; then lock_acquired=1; return 0; fi
    fi
  fi
  return 1
}

download_release_metadata() {
  local node_bin="$1" metadata_path="$2"
  local url="$(release_url)"
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
    process.stdout.write([tag, archiveName, archive.browser_download_url, sumsName, sums.browser_download_url].join("\t"));
  ' "$metadata_path" "$platform_name"
}

installed_integrity_valid() {
  local manifest="$install_root/RELEASE-MANIFEST.sha256" line hash relative path actual count=0
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"; hash="${line%% *}"; relative="${line#* \*}"
    [[ ${#hash} -eq 64 && "$hash" != *[^0-9a-fA-F]* && -n "$relative" && "$relative" != /* && "$relative" != *'../'* && "$relative" != '../'* && "$relative" != *'/..' ]] || return 1
    path="$install_root/$relative"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    actual="$(/usr/bin/shasum -a 256 "$path" | awk '{print $1}')"
    [[ "${actual:l}" == "${hash:l}" ]] || return 1
    (( count += 1 ))
  done < "$manifest"
  (( count > 0 ))
}

assert_safe_destination() {
  local relative="$1" current="$install_root" component
  [[ -d "$install_root" && ! -L "$install_root" ]] || { print -u2 "Install root must be a real directory, not a symbolic link."; return 1; }
  for component in ${(s:/:)relative}; do
    current="$current/$component"
    [[ ! -L "$current" ]] || { print -u2 "Refusing symbolic-link update destination: $relative"; return 1; }
  done
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

rollback_copies() {
  local backup_root="$1" index relative destination backup existed
  for (( index=${#copied_relatives[@]}; index>=1; index-- )); do
    relative="${copied_relatives[$index]}"
    existed="${copied_existed[$index]}"
    destination="$install_root/$relative"
    backup="$backup_root/$relative"
    if [[ "$existed" == 1 ]]; then
      mkdir -p "${destination:h}"
      cp -p -- "$backup" "$destination" || true
    elif [[ -f "$destination" ]]; then
      rm -f -- "$destination" || true
    fi
  done
}

install_release() {
  local tag="$1" archive_name="$2" archive_url="$3" sums_name="$4" sums_url="$5"
  assert_https_url "$archive_url"
  assert_https_url "$sums_url"
  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-remote-update.XXXXXX")"
  local archive_path="$temporary_root/$archive_name" sums_path="$temporary_root/$sums_name"
  /usr/bin/curl --proto '=https' --proto-redir '=https' --fail --location --silent --show-error --max-time 120 "$archive_url" -o "$archive_path"
  /usr/bin/curl --proto '=https' --proto-redir '=https' --fail --location --silent --show-error --max-time 30 "$sums_url" -o "$sums_path"
  local expected actual
  expected="$(tr -d '\r' < "$sums_path" | awk -v name="$archive_name" '$2 == name || $2 == "*" name { print $1; exit }')"
  [[ ${#expected} -eq 64 && "$expected" != *[^0-9a-fA-F]* ]] || { print -u2 "Published archive checksum is missing."; return 1; }
  actual="$(/usr/bin/shasum -a 256 "$archive_path" | awk '{print $1}')"
  [[ "${actual:l}" == "${expected:l}" ]] || { print -u2 "Downloaded archive failed SHA-256 verification."; return 1; }
  local extract_root="$temporary_root/extract"
  mkdir -p "$extract_root"
  if [[ -x /usr/bin/ditto ]]; then
    /usr/bin/ditto -x -k "$archive_path" "$extract_root"
  elif command -v unzip >/dev/null 2>&1; then
    unzip -q "$archive_path" -d "$extract_root"
  else
    print -u2 "Neither ditto nor unzip is available to extract the release."
    return 1
  fi
  local release_root
  if [[ -f "$extract_root/VERSION" ]]; then
    release_root="$extract_root"
  else
    local roots=("$extract_root"/*(/N))
    (( ${#roots[@]} == 1 )) || { print -u2 "Release archive must be flat or contain one top-level directory."; return 1; }
    release_root="${roots[1]}"
  fi
  local archive_version=""
  [[ -f "$release_root/VERSION" ]] && archive_version="$(<"$release_root/VERSION")"
  archive_version="${archive_version//$'\r'/}"
  archive_version="${archive_version//$'\n'/}"
  [[ "$archive_version" == "$tag" ]] || { print -u2 "Archive version does not match release tag."; return 1; }
  local manifest="$release_root/RELEASE-MANIFEST.sha256"
  [[ -f "$manifest" ]] || { print -u2 "Release manifest is missing."; return 1; }
  local -a relatives hashes
  local -A new_relative_set
  local line hash relative source
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    hash="${line%% *}"
    relative="${line#* \*}"
    [[ ${#hash} -eq 64 && "$hash" != *[^0-9a-fA-F]* && -n "$relative" && "$relative" != /* && "$relative" != *'../'* && "$relative" != '../'* && "$relative" != *'/..' ]] || {
      print -u2 "Unsafe or malformed manifest entry: $line"; return 1;
    }
    source="$release_root/$relative"
    [[ -f "$source" && ! -L "$source" ]] || { print -u2 "Release file is missing or linked: $relative"; return 1; }
    actual="$(/usr/bin/shasum -a 256 "$source" | awk '{print $1}')"
    [[ "${actual:l}" == "${hash:l}" ]] || { print -u2 "Release manifest hash mismatch: $relative"; return 1; }
    relatives+=("$relative")
    hashes+=("$hash")
    new_relative_set[$relative]=1
  done < "$manifest"
  local safe_local_version="$(local_version)"
  safe_local_version="${safe_local_version//[^A-Za-z0-9._-]/_}"
  safe_local_version="${safe_local_version[1,48]}"
  local backup_root="$rollback_root/$(date +%Y%m%d-%H%M%S)-$safe_local_version"
  mkdir -p "$backup_root"
  typeset -ga copied_relatives=() copied_existed=()
  local destination backup existed
  for relative in "${relatives[@]}"; do
    [[ "$relative" == 'Update-ChatGPTRemote.sh' ]] && continue
    assert_safe_destination "$relative" || { rollback_copies "$backup_root"; return 1; }
    destination="$install_root/$relative"; backup="$backup_root/$relative"; existed=0
    if [[ -f "$destination" ]]; then existed=1; mkdir -p "${backup:h}"; cp -p -- "$destination" "$backup" && cmp -s -- "$destination" "$backup" || { rollback_copies "$backup_root"; return 1; }; fi
    mkdir -p "${destination:h}"
    cp -p -- "$release_root/$relative" "$destination" || { rollback_copies "$backup_root"; return 1; }
    [[ "$relative" == *.sh ]] && chmod 755 "$destination"
    copied_relatives+=("$relative"); copied_existed+=("$existed")
  done
  local previous_manifest="$install_root/RELEASE-MANIFEST.sha256" old_hash old_relative old_actual
  if [[ -f "$previous_manifest" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"; old_hash="${line%% *}"; old_relative="${line#* \*}"
      [[ ${#old_hash} -eq 64 && "$old_hash" != *[^0-9a-fA-F]* && -n "$old_relative" && "$old_relative" != /* && "$old_relative" != *'../'* && "$old_relative" != '../'* && "$old_relative" != *'/..' ]] || continue
      [[ -n "${new_relative_set[$old_relative]-}" ]] && continue
      destination="$install_root/$old_relative"; backup="$backup_root/$old_relative"
      [[ -f "$destination" && ! -L "$destination" ]] || continue
      old_actual="$(/usr/bin/shasum -a 256 "$destination" | awk '{print $1}')"
      [[ "${old_actual:l}" == "${old_hash:l}" ]] || continue
      mkdir -p "${backup:h}"; cp -p -- "$destination" "$backup" && cmp -s -- "$destination" "$backup" || { rollback_copies "$backup_root"; return 1; }
      rm -f -- "$destination" || { rollback_copies "$backup_root"; return 1; }
      copied_relatives+=("$old_relative"); copied_existed+=(1)
    done < "$previous_manifest"
  fi
  relative='Update-ChatGPTRemote.sh'
  if (( ${relatives[(Ie)$relative]} )); then
    assert_safe_destination "$relative" || { rollback_copies "$backup_root"; return 1; }
    destination="$install_root/$relative"; backup="$backup_root/$relative"; existed=0
    if [[ -f "$destination" ]]; then existed=1; cp -p -- "$destination" "$backup" && cmp -s -- "$destination" "$backup" || { rollback_copies "$backup_root"; return 1; }; fi
    cp -p -- "$release_root/$relative" "$destination" || { rollback_copies "$backup_root"; return 1; }
    chmod 755 "$destination"
    copied_relatives+=("$relative"); copied_existed+=("$existed")
  fi
  relative='RELEASE-MANIFEST.sha256'; assert_safe_destination "$relative" || { rollback_copies "$backup_root"; return 1; }; destination="$install_root/$relative"; backup="$backup_root/$relative"; existed=0
  if [[ -f "$destination" ]]; then existed=1; cp -p -- "$destination" "$backup" && cmp -s -- "$destination" "$backup" || { rollback_copies "$backup_root"; return 1; }; fi
  cp -p -- "$manifest" "$destination" || { rollback_copies "$backup_root"; return 1; }
  copied_relatives+=("$relative"); copied_existed+=("$existed")
  print -r -- "{\"updated\":true,\"version\":\"$tag\",\"files\":${#relatives[@]},\"rollbackPath\":\"$backup_root\"}"
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
  auto)
    if auto_disabled; then print '{"skipped":true,"reason":"auto-update-disabled"}'; exit 0; fi
    if ! check_due; then print '{"skipped":true,"reason":"check-interval"}'; exit 0; fi
    ;;
  check|update) ;;
  *) print -u2 "Usage: $0 {auto|check|update|enable-auto-update|disable-auto-update|probe}"; exit 2 ;;
esac

if ! acquire_lock; then print '{"skipped":true,"reason":"update-already-running"}'; exit 0; fi
typeset node_bin="$(resolve_node)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-remote-update.XXXXXX")"
typeset metadata="$temporary_root/release.json" values tag archive_name archive_url sums_name sums_url
values="$(download_release_metadata "$node_bin" "$metadata")"
IFS=$'\t' read -r tag archive_name archive_url sums_name sums_url <<< "$values"
mkdir -p "$state_root"
print -r -- "{\"checkedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"repository\":\"$repository\",\"tag\":\"$tag\"}" > "$last_check"
typeset current="$(local_version)" available=false
if version_is_newer "$node_bin" "$tag" "$current"; then available=true; fi
if [[ "$tag" == "$current" ]] && ! installed_integrity_valid; then available=true; fi
if [[ "$action" == check || "$available" == false ]]; then
  print -r -- "{\"available\":$available,\"latestVersion\":\"$tag\",\"localVersion\":\"$current\",\"updated\":false}"
  exit 0
fi
cleanup
lock_acquired=0
temporary_root=""
acquire_lock || { print -u2 'Could not reacquire update lock.'; exit 1; }
install_release "$tag" "$archive_name" "$archive_url" "$sums_name" "$sums_url"
