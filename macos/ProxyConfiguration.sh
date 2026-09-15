#!/bin/zsh
set -euo pipefail

action="${1:-probe}"
config_root="$HOME/Library/Application Support/CodexRemoteFeatures"
config_path="${CHATGPT_REMOTE_PROXY_CONFIG_PATH:-$config_root/remote-proxy}"

resolve_node() {
  local candidate
  for candidate in "${CHATGPT_REMOTE_NODE:-}" "$(command -v node 2>/dev/null || true)" /opt/homebrew/bin/node /usr/local/bin/node; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    "$candidate" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)' >/dev/null 2>&1 && { print -r -- "$candidate"; return 0; }
  done
  print -u2 'Node.js 22 or newer is required to validate the proxy configuration.'
  return 1
}

normalize_proxy() {
  local node_bin="$1" value="$2"
  CHATGPT_REMOTE_PROXY_CANDIDATE="$value" "$node_bin" -e '
    const value = process.env.CHATGPT_REMOTE_PROXY_CANDIDATE || "";
    let url; try { url = new URL(value.trim()); } catch { process.exit(2); }
    if (!["http:", "https:"].includes(url.protocol) || !url.hostname || url.username || url.password ||
        !["", "/"].includes(url.pathname) || url.search || url.hash) process.exit(2);
    process.stdout.write(url.origin);
  ' || { print -u2 'The proxy must be an absolute credential-free http:// or https:// authority.'; return 1; }
}

case "${action:l}" in
  install)
    [[ $# -eq 2 ]] || { print -u2 "Usage: $0 install https://proxy.example:8080"; exit 2; }
    node_bin="$(resolve_node)"
    normalized="$(normalize_proxy "$node_bin" "$2")"
    mkdir -m 700 -p "$config_root"
    temporary="$config_path.tmp-$$-$RANDOM"
    print -rn -- "$normalized" > "$temporary"
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$config_path"
    print 'Protected all-connections proxy configuration installed.'
    ;;
  probe)
    [[ -f "$config_path" && ! -L "$config_path" ]] || { print -u2 'No protected proxy configuration is installed.'; exit 1; }
    node_bin="$(resolve_node)"
    normalize_proxy "$node_bin" "$(<"$config_path")" >/dev/null
    print 'Protected all-connections proxy configuration is valid.'
    ;;
  remove)
    [[ -e "$config_path" ]] && rm -f -- "$config_path"
    print 'Protected proxy configuration removed.'
    ;;
  resolve)
    node_bin="$(resolve_node)"
    candidate="${CHATGPT_REMOTE_PROXY_URL:-}"
    if [[ -z "$candidate" && -f "$config_path" && ! -L "$config_path" ]]; then candidate="$(<"$config_path")"; fi
    if [[ -z "$candidate" ]]; then
      system_proxy="$(/usr/sbin/scutil --proxy 2>/dev/null || true)"
      proxy_kind=""
      [[ "$(print -r -- "$system_proxy" | /usr/bin/awk '$1 == "HTTPSEnable" && $3 == 1 { print 1; exit }')" == 1 ]] && proxy_kind='HTTPS'
      [[ -n "$proxy_kind" || "$(print -r -- "$system_proxy" | /usr/bin/awk '$1 == "HTTPEnable" && $3 == 1 { print 1; exit }')" != 1 ]] || proxy_kind='HTTP'
      enabled="$([[ -n "$proxy_kind" ]] && print 1 || true)"
      host="$(print -r -- "$system_proxy" | /usr/bin/awk -v key="${proxy_kind}Proxy" '$1 == key { print $3; exit }')"
      port="$(print -r -- "$system_proxy" | /usr/bin/awk -v key="${proxy_kind}Port" '$1 == key { print $3; exit }')"
      [[ "$enabled" == 1 && -n "$host" && "$port" == <-> ]] && candidate="http://$host:$port"
    fi
    [[ -n "$candidate" ]] || { print -u2 'Proxy mode was requested, but no protected, environment, or fixed macOS system proxy exists.'; exit 1; }
    normalize_proxy "$node_bin" "$candidate"
    ;;
  *) print -u2 "Usage: $0 {install URL|probe|remove|resolve}"; exit 2 ;;
esac
