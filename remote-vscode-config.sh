#!/bin/sh
# Explicit one-click action, streamed as: sh -s -- REMOTE_PORT
# The launcher substitutes the JavaScript marker before streaming this script.
# Uses an existing VS Code server runtime; nothing is downloaded or installed.
if [ "$#" -ne 1 ]; then printf '%s\n' 'VSCODE_ERROR code=invalid_port'; exit 64; fi
remote_port=$1
case "$remote_port" in ''|*[!0-9]*|0*) printf '%s\n' 'VSCODE_ERROR code=invalid_port'; exit 64 ;; esac
if [ "${#remote_port}" -gt 5 ] || [ "$remote_port" -lt 1024 ] || [ "$remote_port" -gt 65535 ]; then
    printf '%s\n' 'VSCODE_ERROR code=invalid_port'; exit 64
fi

node_program=
runtime_seen=no
accept_node() {
    [ -f "$1" ] && [ -x "$1" ] || return 1
    runtime_seen=yes
    # Clear inherited preload options even during the compatibility probe.
    if NODE_OPTIONS= NODE_PATH= "$1" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 12 ? 0 : 1)' </dev/null >/dev/null 2>&1; then
        node_program=$1
        return 0
    fi
    return 1
}
# Prefer the runtime shipped with VS Code over an unrelated old PATH runtime.
for server_root in "${VSCODE_AGENT_FOLDER:-}" "$HOME/.vscode-server" "$HOME/.vscode-server-insiders"; do
    [ -n "$server_root" ] || continue
    for candidate in "$server_root"/cli/servers/*/server/node "$server_root"/bin/*/node; do
        if accept_node "$candidate"; then break; fi
    done
    [ -z "$node_program" ] || break
done
# A custom remote.SSH.serverInstallPath may be visible only in the running
# server. Inspect this account's node processes to locate its existing runtime.
if [ -z "$node_program" ] && command -v ps >/dev/null 2>&1 && command -v id >/dev/null 2>&1 && command -v readlink >/dev/null 2>&1 && command -v tr >/dev/null 2>&1; then
    process_rows=$(ps -u "$(id -u)" -o pid= -o comm= 2>/dev/null) || process_rows=
    while read -r process_id process_name; do
        case "$process_id" in ''|*[!0-9]*) continue ;; esac
        case "$process_name" in node|nodejs) ;; *) continue ;; esac
        [ -r "/proc/$process_id/cmdline" ] || continue
        command_line=$(tr '\000' ' ' < "/proc/$process_id/cmdline" 2>/dev/null) || continue
        case "$command_line" in */out/server-main.js*) ;; *) continue ;; esac
        candidate=$(readlink "/proc/$process_id/exe" 2>/dev/null) || continue
        if accept_node "$candidate"; then break; fi
    done <<CODEX_TUNNEL_PROCESS_LIST
$process_rows
CODEX_TUNNEL_PROCESS_LIST
fi
if [ -z "$node_program" ]; then
    candidate=$(command -v node 2>/dev/null) || candidate=
    [ -z "$candidate" ] || accept_node "$candidate" || :
fi
if [ -z "$node_program" ]; then
    if [ "$runtime_seen" = yes ]; then printf '%s\n' 'VSCODE_ERROR code=unsupported_runtime'
    else printf '%s\n' 'VSCODE_ERROR code=runtime_missing'; fi
    exit 69
fi
# Ignore preload/module injection options inherited by the SSH shell.
NODE_OPTIONS= NODE_PATH= "$node_program" - "$remote_port" <<'CODEX_TUNNEL_VSCODE_JAVASCRIPT'
__CODEX_TUNNEL_VSCODE_JS__
CODEX_TUNNEL_VSCODE_JAVASCRIPT
