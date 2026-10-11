#!/bin/bash
# SSH to the batch-chat main server (key auth from here; password auth also enabled since 2026-10-08)
# Routing order:
#   1. direct                      — works only when DPI lets port 22 through
#   2. via bc-proxy SOCKS5 tunnel  — reliable path (Turkey egress); bc-proxy must be running
#   3. ProxyJump via Russia relay  — last resort (relay port 22 is DPI-blocked often)
HOST="${BC_PROXY_HOST:-$(cat "$HOME/.bc_host")}"
RELAY="${BC_PROXY_RELAY:-62.109.10.170}"
PORT="${BC_PROXY_PORT:-1080}"

banner_ok() {
  timeout "${2:-8}" bash -c "exec 3<>/dev/tcp/$1/22 && timeout ${2:-8} head -c 4 <&3 2>/dev/null" 2>/dev/null | grep -q SSH-
}

if banner_ok "$HOST" 8; then
  exec ssh -o StrictHostKeyChecking=no "root@$HOST" "$@"
fi

if timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
  echo "[bc-ssh] direct SSH to $HOST blocked; routing via bc-proxy SOCKS5 127.0.0.1:$PORT" >&2
  exec ssh -o StrictHostKeyChecking=no -o ProxyCommand="nc -X 5 -x 127.0.0.1:$PORT %h %p" "root@$HOST" "$@"
fi

echo "[bc-ssh] no bc-proxy listening on 127.0.0.1:$PORT; last resort: jump via relay $RELAY" >&2
exec ssh -o StrictHostKeyChecking=no -o ProxyJump="root@$RELAY" "root@$HOST" "$@"
