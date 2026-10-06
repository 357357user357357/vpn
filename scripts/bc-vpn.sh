#!/usr/bin/env bash
# bc-vpn — one-command system-wide egress via the Turkey server.
#
# Mimics the Hiddify experience: type `bc-vpn`, pick "Connect", and ALL
# browsers (Firefox/Chrome/Chromium — anything that follows the system proxy)
# start routing through the Turkey exit (166.1.2.48) via the local SOCKS5
# tunnel managed by ~/bin/bc-proxy.
#
# Russian sites (*.ru/*.su/*.рф), the LAN, and flexchat.top stay DIRECT
# (that logic lives in https://flexchat.top/proxy.pac).
#
# Usage: bc-vpn            # interactive menu
#        bc-vpn connect|disconnect|status|ip
# (Running it as root is never required — the script drops back to the
# desktop user, because KDE/GNOME proxy settings are per-user. It does NOT
# touch the `hiddify` app or any other proxy service on this machine.)
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

  echo "==> Setting SYSTEM-WIDE proxy (all browsers) to auto-config PAC…"
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
  echo "CONNECTED — egress via Turkey ($ip)."
  echo "  Russian sites / LAN / flexchat.top remain DIRECT."
  echo "  Browsers already open may need one restart to pick up the new proxy."
  echo "  Chromium: fully quit ALL windows and relaunch (launcher is PAC-wired)."
  echo "  Turn off anytime:  bc-vpn disconnect"
}

disconnect() {
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
