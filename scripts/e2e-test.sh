#!/usr/bin/env bash
# E2E health checks for the RU relay -> main exit VPN chain.
# Usage: ./e2e-test.sh            (defaults below, or pass hosts as args)
#        ./e2e-test.sh root@RELAY_IP root@MAIN_IP
set -u
RELAY=${1:-root@RELAY_IP}
MAIN=${2:-root@MAIN_IP}
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi; }

echo "== services =="
ssh -o ConnectTimeout=15 "$RELAY" "systemctl is-active xray sing-box-client" >/dev/null && echo "PASS: relay xray + sing-box-client active" || echo "FAIL: relay services"
ssh -o ConnectTimeout=15 "$MAIN" "systemctl is-active xray-main" >/dev/null && echo "PASS: main xray-main active" || echo "FAIL: main xray-main"

echo "== hop 1: relay bridge -> main exit (expect MAIN exit IP) =="
ip1=$(ssh -o ConnectTimeout=15 "$RELAY" "curl -s --socks5-hostname 127.0.0.1:10809 --max-time 12 https://api.ipify.org")
chk "bridge exit ip" "$ip1" "MAIN_IP"

echo "== hop 2: full chain via temp vless client on relay (expect MAIN exit IP) =="
# Temp client: xray run -c /tmp/xray-test-client.json with:
#   inbound socks 127.0.0.1:10808 -> outbound vless+REALITY to 127.0.0.1:443
#   uuid=<PHONE_UUID> sni=kz-ala-1.blook.network pbk=<PHONE_PUBLIC_KEY> sid=<PHONE_SHORT_ID> fp=chrome
#   routing: everything -> that outbound. See README "Parameters" for values.
if ssh "$RELAY" "test -f /tmp/xray-test-client.json"; then
  ssh "$RELAY" "setsid nohup xray run -c /tmp/xray-test-client.json >/tmp/xr-cl.log 2>&1 </dev/null & sleep 2"
  ip2=$(ssh -o ConnectTimeout=15 "$RELAY" "curl -s --socks5-hostname 127.0.0.1:10808 --max-time 15 https://api.ipify.org")
  chk "full-chain exit ip" "$ip2" "MAIN_IP"
  code=$(ssh -o ConnectTimeout=15 "$RELAY" "curl -s --socks5-hostname 127.0.0.1:10808 --max-time 15 -o /dev/null -w '%{http_code}' https://flexchat.top/health")
  chk "flexchat.top/health via chain" "$code" "200"
  ssh "$RELAY" "pkill -f 'xr[a]y run -c /tmp/xray-test-client.json' 2>/dev/null" # careful pattern, never bare pkill -f xray
else
  echo "SKIP: /tmp/xray-test-client.json not present on relay (see comment above)"
fi

echo "== nextcloud still direct (bypasses VPN) =="
nc=$(ssh -o ConnectTimeout=15 "$RELAY" "curl -s -H 'Host: RELAY_IP' http://127.0.0.1/status.php | head -c 40")
echo "relay-local status.php: $nc"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
