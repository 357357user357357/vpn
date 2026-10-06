#!/usr/bin/env bash
# bc-proxy — personal egress via the Turkey server (166.1.2.48).
#
# Opens a local SOCKS5 proxy on 127.0.0.1:$PORT (default 1080) that forwards
# through an SSH dynamic tunnel to the Turkey server. No server-side changes
# needed; works for any browser/app that can use a SOCKS5 proxy.
#
# Browser setup: auto-config URL  https://flexchat.top/proxy.pac
# (the PAC routes everything through 127.0.0.1:1080 EXCEPT Russian sites,
# LAN, and flexchat.top itself — those stay direct).
#
# Usage: bc-proxy start|stop|status|restart|ip
set -u

HOST="${BC_PROXY_HOST:-166.1.2.48}"
PORT="${BC_PROXY_PORT:-1080}"
PIDFILE="/tmp/bc-proxy-$PORT.pid"
LOG="/tmp/bc-proxy-$PORT.log"

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=25
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -o ExitOnForwardFailure=yes
  -o StrictHostKeyChecking=accept-new
  -N -D "127.0.0.1:$PORT" "root@$HOST"
)

loop_pid() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

start() {
  if loop_pid; then
    echo "bc-proxy already running (pid $(cat "$PIDFILE")), SOCKS5 127.0.0.1:$PORT"
    return 0
  fi
  # Clear stale pidfile and anything squatting on the port.
  rm -f "$PIDFILE"
  pkill -f "ssh .*-N -D 127.0.0.1:$PORT" 2>/dev/null
  nohup bash -c '
    while true; do
      ssh '"${SSH_OPTS[*]}"' && break
      sleep 3
    done
  ' >>"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  sleep 2
  if loop_pid; then
    echo "bc-proxy started (pid $(cat "$PIDFILE")), SOCKS5 127.0.0.1:$PORT (log: $LOG)"
  else
    echo "bc-proxy FAILED to start, see $LOG" >&2
    return 1
  fi
}

stop() {
  if loop_pid; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    sleep 1
  fi
  rm -f "$PIDFILE"
  pkill -f "ssh .*-N -D 127.0.0.1:$PORT" 2>/dev/null
  echo "bc-proxy stopped"
}

status() {
  if loop_pid; then
    echo "running (pid $(cat "$PIDFILE"))"
  else
    echo "not running"
    return 1
  fi
  ip
}

ip() {
  local out
  out=$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:$PORT" https://api.ipify.org)
  if [[ -n "$out" ]]; then
    echo "egress IP via proxy: $out"
  else
    echo "proxy check FAILED (tunnel up but no egress?)" >&2
    return 1
  fi
}

case "${1:-status}" in
  start) start ;;
  stop) stop ;;
  restart) stop; sleep 1; start ;;
  status) status ;;
  ip) ip ;;
  *) echo "usage: $0 {start|stop|restart|status|ip}" >&2; exit 2 ;;
esac
