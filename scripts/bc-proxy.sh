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
RELAY="${BC_PROXY_RELAY:-62.109.10.170}"   # Russia relay; used as ProxyJump when direct SSH is blocked
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

# True if an SSH banner arrives from $1 within $2 seconds. Detects DPI that
# completes the TCP handshake but silently drops SSH.
banner_ok() {
  timeout "$2" bash -c "exec 3<>/dev/tcp/$1/22 && timeout $2 head -c 4 <&3 2>/dev/null" 2>/dev/null | grep -q SSH-
}

tunnel_loop() {
  while true; do
    if banner_ok "$HOST" 10; then
      echo "[bc-proxy] $(date '+%H:%M:%S') route: direct -> $HOST" >>"$LOG"
      ssh "${SSH_OPTS[@]}" "root@$HOST" || true
    else
      echo "[bc-proxy] $(date '+%H:%M:%S') direct SSH blocked; route: via relay $RELAY" >>"$LOG"
      ssh -o ProxyJump="root@$RELAY" "${SSH_OPTS[@]}" "root@$HOST" || true
    fi
    sleep 3
  done
}

start() {
  if loop_pid; then
    echo "bc-proxy already running (pid $(cat "$PIDFILE")), SOCKS5 127.0.0.1:$PORT"
    return 0
  fi
  # Clear stale pidfile and anything squatting on the port.
  rm -f "$PIDFILE"
  pkill -f "ssh .*-N -D 127.0.0.1:$PORT" 2>/dev/null
  setsid nohup "$0" _loop >>"$LOG" 2>&1 &
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
  _loop) tunnel_loop ;;
  *) echo "usage: $0 {start|stop|restart|status|ip}" >&2; exit 2 ;;
esac
