#!/usr/bin/env bash
# bc-vpn — one-command system-wide egress via the Turkey server.
#
# Mimics the Hiddify experience: type `bc-vpn`, pick "Connect", and ALL
# browsers (Firefox/Chrome/Chromium — anything that follows the system proxy)
# start routing through the Turkey exit (166.1.2.48) via the local SOCKS5
# tunnel managed by ~/bin/bc-proxy.
#
# Russian sites (*.ru/*.su/*.рф), the LAN, and flexchat.top stay DIRECT
# (that logic lives in https://flexchat.top/proxy.pac and is mirrored in the
# TUN config below).
#
# Modes:
#   TUN (preferred): a sing-box TUN device captures ALL traffic at the IP
#     layer — running apps (even open browsers) re-route with NO restart.
#     Needs sudo once per session (same as `sudo hiddify`).
#   PAC (fallback): system PAC for browsers that follow it; running browsers
#     need one restart (and snap Chromium needs the launcher override).
#
# Usage: bc-vpn            # interactive menu
#        bc-vpn connect|disconnect|status|ip
# (It does NOT touch the `hiddify` app or any other proxy service.)
set -u

PAC_URL="https://flexchat.top/proxy.pac"

# If launched with sudo, re-exec as the real desktop user (proxy settings
# and the ssh key live in that user's session/home).
if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  exec runuser -u "$SUDO_USER" -- "$0" "$@"
fi

# --- helpers ---------------------------------------------------------------
kset() { # kset key value  — KDE system proxy (Plasma 5/6)
  if command -v kwriteconfig6 >/dev/null; then
    kwriteconfig6 --file kioslaverc --group "Proxy Settings" --key "$1" "$2"
  elif command -v kwriteconfig5 >/dev/null; then
    kwriteconfig5 --file kioslaverc --group "Proxy Settings" --key "$1" "$2"
  fi
}
kget() {
  kreadconfig5 --file kioslaverc --group "Proxy Settings" --key "$1" 2>/dev/null \
    || kreadconfig6 --file kioslaverc --group "Proxy Settings" --key "$1" 2>/dev/null
}
notify_kde() { # ask running KDE apps to re-read proxy config (best effort)
  qdbus6 org.kde.KIO /KIO/Scheduler org.kde.KIO.Scheduler.reparseSlaveConfiguration 2>/dev/null || true
}

tunnel_up() { ~/bin/bc-proxy status >/dev/null 2>&1; }

CHROMIUM_DESKTOP_UPSTREAM=/var/lib/snapd/desktop/applications/chromium_chromium.desktop
CHROMIUM_DESKTOP_LOCAL="$HOME/.local/share/applications/chromium_chromium.desktop"

# Snap Chromium ignores the system proxy settings (gsettings PAC/manual and
# KDE kioslaverc), so give its launcher the PAC explicitly. The PAC falls
# back to DIRECT when the tunnel is off, so the override is safe to keep
# installed permanently.
ensure_chromium_pac() {
  [[ -f "$CHROMIUM_DESKTOP_UPSTREAM" ]] || return 0
  if [[ -f "$CHROMIUM_DESKTOP_LOCAL" ]] \
     && grep -q -- "--proxy-pac-url=$PAC_URL" "$CHROMIUM_DESKTOP_LOCAL"; then
    return 0
  fi
  mkdir -p "$HOME/.local/share/applications"
  sed "s|^Exec=/snap/bin/chromium|Exec=/snap/bin/chromium --proxy-pac-url=$PAC_URL|" \
    "$CHROMIUM_DESKTOP_UPSTREAM" > "$CHROMIUM_DESKTOP_LOCAL"
}

chromium_pac_installed() {
  [[ -f "$CHROMIUM_DESKTOP_LOCAL" ]] \
    && grep -q -- "--proxy-pac-url=$PAC_URL" "$CHROMIUM_DESKTOP_LOCAL"
}

egress() { # prints egress IP seen through the tunnel, or empty
  curl -s --max-time 15 --socks5-hostname 127.0.0.1:1080 https://api.ipify.org 2>/dev/null
}

# --- TUN mode (no browser restarts needed) ---------------------------------
SINGBOX="$HOME/.local/bin/bc-singbox"
SINGBOX_VER=1.11.15
TUN_CONF="$HOME/.config/bc-vpn/tun.json"
TUN_LOG=/tmp/bc-tun.log

ensure_singbox() { # download pinned sing-box via our own tunnel if absent
  [[ -x "$SINGBOX" ]] && return 0
  echo "==> Fetching sing-box v$SINGBOX_VER (one-time, via tunnel)…"
  mkdir -p "$HOME/.local/bin"
  local t; t="$(mktemp -d)" || return 1
  curl -sL --max-time 180 --socks5-hostname 127.0.0.1:1080 \
    -o "$t/sb.tgz" \
    "https://github.com/SagerNet/sing-box/releases/download/v$SINGBOX_VER/sing-box-$SINGBOX_VER-linux-amd64.tar.gz" \
    && tar -xzf "$t/sb.tgz" -C "$t" \
    && cp "$t/sing-box-$SINGBOX_VER-linux-amd64/sing-box" "$SINGBOX" \
    && chmod +x "$SINGBOX"
  local rc=$?
  rm -rf "$t"
  return $rc
}

write_tun_conf() { # config mirroring the PAC: RU/LAN/flexchat direct, rest via socks
  mkdir -p "$(dirname "$TUN_CONF")"
  cat > "$TUN_CONF" <<EOF
{
  "log": {"level": "warn", "output": "$TUN_LOG", "timestamp": true},
  "dns": {
    "servers": [
      {"tag": "proxy-dns", "address": "tcp://1.1.1.1", "detour": "socks-out"},
      {"tag": "local-dns", "address": "local", "detour": "direct"}
    ],
    "rules": [
      {"domain_suffix": ["ru", "su", "xn--p1ai", "flexchat.top"], "server": "local-dns"}
    ],
    "final": "proxy-dns",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "mtu": 1400,
      "auto_route": true,
      "strict_route": false,
      "stack": "gvisor"
    }
  ],
  "outbounds": [
    {"type": "socks", "tag": "socks-out", "server": "127.0.0.1", "server_port": 1080},
    {"type": "direct", "tag": "direct"},
    {"type": "dns", "tag": "dns-out"}
  ],
  "route": {
    "rules": [
      {"inbound": "tun-in", "action": "sniff"},
      {"protocol": "dns", "action": "hijack-dns"},
      {"network": "udp", "port": 443, "action": "reject"},
      {"ip_is_private": true, "outbound": "direct"},
      {"domain_suffix": ["ru", "su", "xn--p1ai", "flexchat.top"], "outbound": "direct"},
      {"ip_cidr": ["166.1.2.48/32", "62.109.10.170/32"], "outbound": "direct"}
    ],
    "final": "socks-out",
    "auto_detect_interface": true
  }
}
EOF
  chmod 644 "$TUN_CONF"  # root (sing-box) must be able to read it
}

tun_running() { pgrep -f 'bc-singbox run' >/dev/null 2>&1; }

start_tun() { # returns 0 if TUN is up; needs sudo once (cached credentials ok)
  ensure_singbox || { echo "WARN: sing-box unavailable ($TUN_LOG side); using PAC mode."; return 1; }
  write_tun_conf
  "$SINGBOX" check -c "$TUN_CONF" || { echo "WARN: TUN config invalid; using PAC mode."; return 1; }
  if [[ "$(id -u)" -eq 0 ]]; then
    :
  elif ! sudo -n true 2>/dev/null; then
    echo "==> TUN mode needs your sudo password (one time per session):"
    sudo -v || { echo "WARN: no sudo — falling back to PAC mode."; return 1; }
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    setsid nohup "$SINGBOX" run -c "$TUN_CONF" >>"$TUN_LOG" 2>&1 &
  else
    sudo -n -b sh -c "exec '$SINGBOX' run -c '$TUN_CONF' >>'$TUN_LOG' 2>&1"
  fi
  sleep 2
  if tun_running; then
    echo "==> TUN device up — ALL apps (including open browsers) now route via Turkey. No restarts."
    return 0
  fi
  echo "WARN: TUN device did not come up (see $TUN_LOG); using PAC mode."
  return 1
}

stop_tun() {
  tun_running || return 0
  if [[ "$(id -u)" -eq 0 ]] || sudo -n true 2>/dev/null; then
    sudo -n pkill -TERM -f 'bc-singbox run' 2>/dev/null || pkill -TERM -f 'bc-singbox run'
  else
    echo "NOTE: run 'sudo pkill -f bc-singbox' to stop the TUN device."
    return 1
  fi
  sleep 1
  tun_running && return 1 || return 0
}

# --- actions ---------------------------------------------------------------
connect() {
  echo "==> Starting tunnel to Turkey (166.1.2.48)…"
  ~/bin/bc-proxy start
  # Tunnel startup is asynchronous (retry loop in background); wait for egress.
  local ip="" i
  for i in $(seq 1 10); do
    ip="$(egress)" && [[ -n "$ip" ]] && break
    sleep 2
  done
  if [[ -z "$ip" ]]; then
    echo "ERROR: tunnel did not come up (see /tmp/bc-proxy-1080.log). System proxy NOT changed."
    exit 1
  fi
  echo "==> Tunnel up. Egress IP: $ip"

  start_tun
  if tun_running; then
    echo
    echo "CONNECTED (TUN) — everything routes via Turkey ($ip). No browser restarts needed."
    echo "  Russian sites / LAN / flexchat.top remain DIRECT."
    echo "  Turn off anytime:  bc-vpn disconnect"
    return 0
  fi

  echo "==> Falling back to PAC mode (system proxy for browsers)…"
  # KDE/Plasma: PAC mode (ProxyType 2 = automatic config script)
  kset ProxyType 2
  kset "Proxy Config Script" "$PAC_URL"
  kset ReversedException false
  # GNOME fallback (harmless under KDE, useful under GNOME sessions)
  gsettings set org.gnome.system.proxy mode 'auto' 2>/dev/null || true
  gsettings set org.gnome.system.proxy autoconfig-url "$PAC_URL" 2>/dev/null || true
  notify_kde
  ensure_chromium_pac

  echo
  echo "CONNECTED (PAC) — egress via Turkey ($ip)."
  echo "  Russian sites / LAN / flexchat.top remain DIRECT."
  echo "  Browsers already open may need one restart to pick up the new proxy."
  echo "  Chromium: fully quit ALL windows and relaunch (launcher is PAC-wired)."
  echo "  (For zero-restart routing run connect again inside a sudo shell.)"
  echo "  Turn off anytime:  bc-vpn disconnect"
}

disconnect() {
  echo "==> Stopping TUN device (if any)…"
  if stop_tun; then
    echo "    TUN stopped."
  else
    echo "    TUN still running — see note above."
  fi
  echo "==> Removing system proxy (back to direct)…"
  kset ProxyType 0
  kset "Proxy Config Script" ""
  gsettings set org.gnome.system.proxy mode 'none' 2>/dev/null || true
  notify_kde
  echo "==> Stopping tunnel…"
  ~/bin/bc-proxy stop
  echo
  echo "DISCONNECTED — normal direct connection restored."
}

status() {
  if tun_running; then
    echo "TUN device: UP — ALL apps route via Turkey (no restarts needed)"
  else
    echo "TUN device: down"
  fi
  if ! tunnel_up; then
    echo "Tunnel: DOWN"
  else
    local ip; ip="$(egress)"
    echo "Tunnel: UP (SOCKS5 127.0.0.1:1080), egress IP: ${ip:-checking…}"
  fi
  local pt; pt="$(kget ProxyType)"
  case "$pt" in
    2) echo "System proxy: ON  (PAC $PAC_URL)" ;;
    0|""|2*) : ;;
    *) echo "System proxy: custom mode ($pt) — bc-vpn did not set this" ;;
  esac
  [[ "$pt" == "2" ]] || echo "System proxy: OFF (direct)"
  echo "Chromium launcher: $(chromium_pac_installed \
    && echo 'PAC-wired (new windows follow the PAC)' \
    || echo 'not wired — run: bc-vpn connect')"
  echo "All browsers: $( { [[ "$pt" == "2" ]] && tunnel_up; } && echo 'routing via Turkey' || echo 'direct / needs connect')"
}

ip() {
  local ip; ip="$(egress)"
  if [[ -n "$ip" ]]; then
    echo "Websites see you as: $ip (Turkey exit)"
  else
    echo "Tunnel not responding (run: bc-vpn connect)"
  fi
}

menu() {
  echo "================ bc-vpn (Turkey egress) ================"
  status
  echo "---------------------------------------------------------"
  echo "  1) Connect    (all browsers -> Turkey)"
  echo "  2) Disconnect (back to direct)"
  echo "  3) Status"
  echo "  4) Exit"
  printf "Choose [1-4]: "
  local c
  read -r c
  case "$c" in
    1) connect ;;
    2) disconnect ;;
    3) status ;;
    *) exit 0 ;;
  esac
}

case "${1:-menu}" in
  connect)    connect ;;
  disconnect) disconnect ;;
  status)     status ;;
  ip)         ip ;;
  menu|"")    menu ;;
  *) echo "usage: bc-vpn [connect|disconnect|status|ip]"; exit 2 ;;
esac
