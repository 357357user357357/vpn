#!/usr/bin/env bash
# E2E health checks for the RU relay -> main exit VPN chain.
# Usage: ./e2e-test.sh            (defaults below, or pass hosts as args)
#        ./e2e-test.sh root@RELAY_IP root@MAIN_IP
set -u
RELAY=${1:-root@RELAY_IP}
MAIN=${2:-root@MAIN_IP}
# Expected foreign-exit IP (the main server's IP) — sanitized default matches
# nothing on purpose; pass EXPECTED_EXIT_IP=<main ip> for real checks.
EXPECTED=${EXPECTED_EXIT_IP:-MAIN_IP}
SSH="ssh -o ConnectTimeout=15"
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi; }
cleanup() { $SSH "$RELAY" "pkill -f 'xr[a]y run -c /tmp/xray-test-client.json' 2>/dev/null" >/dev/null 2>&1; }

echo "== services =="
$SSH "$RELAY" "systemctl is-active xray sing-box-client" >/dev/null 2>&1
chk "relay xray + sing-box-client active" "$?" 0
$SSH "$MAIN" "systemctl is-active xray-main" >/dev/null 2>&1
chk "main xray-main active" "$?" 0

echo "== hop 1: relay bridge -> main exit (expect MAIN exit IP) =="
ip1=$($SSH "$RELAY" "curl -s --socks5-hostname 127.0.0.1:10809 --max-time 12 https://api.ipify.org")
chk "bridge exit ip" "$ip1" "$EXPECTED"

echo "== hop 2: full chain via temp vless client on relay (expect MAIN exit IP) =="
# Temp client: xray run -c /tmp/xray-test-client.json with:
#   inbound socks 127.0.0.1:10808 -> outbound vless+REALITY to 127.0.0.1:443
#   uuid=<PHONE_UUID> sni=<CAMO_RELAY_DOMAIN> pbk=<PHONE_PUBLIC_KEY> sid=<PHONE_SHORT_ID> fp=chrome
#   routing: everything -> that outbound. See README "Parameters" for values.
if $SSH "$RELAY" "test -f /tmp/xray-test-client.json"; then
  trap cleanup EXIT
  cleanup   # kill any stale temp client holding :10808
  $SSH "$RELAY" "setsid nohup xray run -c /tmp/xray-test-client.json >/tmp/xr-cl.log 2>&1 </dev/null & true"
  ready=0
  for _ in $(seq 1 15); do
    $SSH "$RELAY" "ss -tln | grep -q ':10808 '" && ready=1 && break
    sleep 1
  done
  if [ "$ready" = 1 ]; then
    ip2=$($SSH "$RELAY" "curl -s --socks5-hostname 127.0.0.1:10808 --max-time 15 https://api.ipify.org")
    chk "full-chain exit ip" "$ip2" "$EXPECTED"
    code=$($SSH "$RELAY" "curl -s --socks5-hostname 127.0.0.1:10808 --max-time 15 -o /dev/null -w '%{http_code}' https://flexchat.top/health")
    chk "flexchat.top/health via chain" "$code" "200"
  else
    echo "FAIL: temp vless client not ready on :10808 after 15 tries"
    fail=$((fail+1))
  fi
else
  echo "SKIP: /tmp/xray-test-client.json not present on relay (see comment above)"
fi

echo "== nextcloud still direct (bypasses VPN) =="
nc=$($SSH "$RELAY" "curl -s -H 'Host: ${RELAY#*@}' http://127.0.0.1/status.php | grep -o '\"installed\":true' | head -1")
chk "nextcloud status.php relay-local" "$nc" '"installed":true'

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
