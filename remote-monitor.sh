#!/bin/sh
# Streamed over SSH stdin: sh -s -- REMOTE_PORT CHECK_INTERVAL [once]
# Nothing is installed or written on the remote host. "once" is a bounded check.

usage() {
    printf '%s\n' 'Usage: sh -s -- PORT INTERVAL [once] (PORT 1..65535; INTERVAL 4..86400 seconds; no leading zeros)' >&2
    exit 64
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
remote_port=$1
check_interval=$2
run_mode=${3:-monitor}
case "$remote_port" in ''|*[!0-9]*|0*) usage ;; esac
case "$check_interval" in ''|*[!0-9]*|0*) usage ;; esac
[ "${#remote_port}" -le 5 ] && [ "$remote_port" -le 65535 ] || usage
[ "${#check_interval}" -le 5 ] && [ "$check_interval" -ge 4 ] && [ "$check_interval" -le 86400 ] || usage
case "$run_mode" in monitor|once) ;; *) usage ;; esac
# Only omission selects monitor mode; an explicit third argument must be once.
[ "$#" -eq 2 ] || [ "$run_mode" = once ] || usage

LC_ALL=C
export LC_ALL
sleep_pid=
state=starting
ever_ready=no
last_result=2

stamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' 'time-unavailable'
}

report() {
    # A closed SSH output pipe also ends the monitor. stdin is already EOF after
    # the streamed script, so reading stdin would incorrectly stop a live tunnel.
    printf '[%s] %s\n' "$(stamp)" "$*" || exit 0
}

cleanup() {
    trap - 0 HUP INT TERM PIPE
    if [ -n "$sleep_pid" ]; then
        # This PID is exclusively the sleep child created by this script.
        kill "$sleep_pid" 2>/dev/null || :
        wait "$sleep_pid" 2>/dev/null || :
    fi
    printf '%s\n' 'TUNNEL_STOPPED remote monitor ended.' 2>/dev/null || :
}
trap cleanup 0
trap 'exit 0' HUP INT TERM PIPE

pause_monitor() {
    # wait on a child lets POSIX shells process a hangup promptly during sleep.
    sleep "$1" &
    sleep_pid=$!
    wait "$sleep_pid" || :
    sleep_pid=
}

check_listener_binding() {
    # sshd GatewayPorts can override the requested loopback bind. Inspect only;
    # no server configuration or other listener/process is modified.
    if ! command -v ss >/dev/null 2>&1; then
        report 'TUNNEL_BIND_UNVERIFIED ss is missing; listener binding requires a manual check. Target connectivity is checked separately.'
        return
    fi
    if ! listener_rows=$(ss -H -ltn </dev/null 2>/dev/null); then
        report 'TUNNEL_BIND_UNVERIFIED ss could not read TCP listeners; listener binding requires a manual check. Target connectivity is checked separately.'
        return
    fi
    matched_listener=no
    # A here-document keeps loop state in this shell and adds no dependencies.
    # ss -H -ltn columns: State Recv-Q Send-Q LocalAddress:Port PeerAddress:Port.
    while read -r bind_state bind_recv bind_send bind_local bind_peer bind_extra; do
        [ "$bind_state" = LISTEN ] || continue
        [ "${bind_local##*:}" = "$remote_port" ] || continue
        matched_listener=yes
        bind_address=${bind_local%:*}
        case "$bind_address" in
            127.0.0.1|'[::1]'|::1) ;;
            *)
                report "TUNNEL_BIND_UNSAFE port $remote_port listens on $bind_address instead of the expected loopback address. Ending this SSH session; check server GatewayPorts policy."
                exit 78
                ;;
        esac
    done <<EOF
$listener_rows
EOF
    if [ "$matched_listener" = no ]; then
        report "TUNNEL_BIND_UNVERIFIED no readable TCP listener matched port $remote_port; listener binding requires a manual check. Target connectivity is checked separately."
    fi
}

check_route() {
    if ! command -v curl >/dev/null 2>&1; then
        if [ "$state" != unverified ]; then
            report 'TUNNEL_UNVERIFIED curl is missing; install/check curl manually. Forward remains open; target access is not verified.'
        else
            report 'TUNNEL_HEARTBEAT UNVERIFIED curl is missing; manual check required.'
        fi
        state=unverified
        last_result=2
        return
    fi

    # -q must be first: ignore remote .curlrc, including insecure TLS settings.
    # Explicit proxy and empty noproxy prevent environment bypass. http_code is
    # the final target response, never http_connect (the proxy CONNECT response).
    # No credentials are sent; successful TLS + HTTP 401 is expected.
    http_code=$(curl -q --silent --show-error \
        --noproxy '' --proxy "http://127.0.0.1:$remote_port" \
        --connect-timeout 5 --max-time 15 \
        --output /dev/null --write-out '%{http_code}' \
        'https://api.openai.com/v1/models' </dev/null 2>/dev/null)
    curl_exit=$?
    healthy=no
    if [ "$curl_exit" -eq 0 ]; then
        case "$http_code" in 401|2[0-9][0-9]) healthy=yes ;; esac
    fi

    if [ "$healthy" = yes ]; then
        if [ "$state" = degraded ] || [ "$state" = unverified ]; then
            report "TUNNEL_RECOVERED remote target TLS/HTTP restored (HTTP $http_code)."
        fi
        if [ "$ever_ready" = no ]; then
            report "TUNNEL_READY remote HTTPS via 127.0.0.1:$remote_port verified (HTTP $http_code); login/model inference not tested. Keep this SSH window open."
            ever_ready=yes
        elif [ "$state" = healthy ]; then
            report "TUNNEL_HEARTBEAT HEALTHY target_http=$http_code"
        fi
        state=healthy
        last_result=0
    else
        if [ "$curl_exit" -eq 0 ] && [ "$http_code" = 403 ]; then
            detail='HTTP 403: TLS/HTTP reachable; route/account access not verified. Check proxy exit route or service restrictions.'
        else
            # Do not echo arbitrary curl output as a status line.
            case "$http_code" in [0-9][0-9][0-9]) ;; *) http_code=invalid ;; esac
            detail="target_http=$http_code curl_exit=$curl_exit; target access not verified. Check local proxy, SSH forward and remote TLS trust."
        fi
        if [ "$state" != degraded ] || [ "${last_failure:-}" != "$detail" ]; then
            report "TUNNEL_DEGRADED $detail Forward remains open; checks will continue."
        else
            report "TUNNEL_HEARTBEAT DEGRADED $detail"
        fi
        last_failure=$detail
        state=degraded
        last_result=1
    fi
}

# Check binding before any target request; unsafe binding closes our SSH session.
check_listener_binding

# At most two startup probes, each at most 15 seconds, with a short retry delay.
check_route
if [ "$last_result" -eq 1 ]; then
    pause_monitor 2
    check_route
fi
[ "$run_mode" != once ] || exit "$last_result"

while :; do
    pause_monitor "$check_interval"
    check_route
done
