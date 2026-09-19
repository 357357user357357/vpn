# vpn

VPN-style forwarding chain: RU relay → foreign exit on the main server. Phone/PC clients connect to the **relay** (existing config, unchanged); all traffic except Nextcloud exits through the **main server**.

Repos are kept **public — all secrets are sanitized**. Real values live only on the servers (paths listed below).

## Topology

```
phone / PC (vless+REALITY client, params unchanged)
   │
   ▼
RU relay (<RELAY_IP>) — xray :443  [phone-facing inbound, vless+REALITY]
   │  routing: dest <RELAY_IP> → direct   (Nextcloud stays local/fast)
   │  everything else → outbound "to-main"
   ▼
socks 127.0.0.1:10809 — sing-box client bridge (systemd: sing-box-client)
   │  vless+REALITY to <MAIN_IP>:39443, SNI flexchat.top, uTLS chrome
   ▼
main server (<MAIN_IP>) — xray-main :39443  [foreign exit, vless+REALITY]
   │  routing: dest <MAIN_IP> → direct (loop protection)
   ▼
freedom outbound (UseIPv4 — main has NO IPv6) → internet
```

Verified end-to-end: client through relay exits as `<MAIN_IP>`; `https://flexchat.top/health` returns 200 through the full chain.

## Components

| Server | Role | Binary | Version | Port | Unit |
|---|---|---|---|---|---|
| relay (Ubuntu 26.04.1) | phone-facing inbound + router | xray | 25.12.8 | 443 | `xray` |
| relay | bridge → main exit | sing-box | 1.12.14 | 127.0.0.1:10809 | `sing-box-client` |
| main (Ubuntu 26.04.1) | foreign exit | xray | 26.3.27 | 39443 | `xray-main` |

## Files

```
relay/xray-config.json         → /usr/local/etc/xray/config.json      (relay)
relay/xray.service             → /etc/systemd/system/xray.service     (relay)
relay/sing-box-client.json     → /etc/sing-box/config.json            (relay)
relay/sing-box-client.service  → /etc/systemd/system/sing-box-client.service (relay)
main/xray-config.json          → /usr/local/etc/xray/config.json      (main)
main/xray-main.service         → /etc/systemd/system/xray-main.service (main)
scripts/e2e-test.sh            → chain health checks (run from admin box)
```

## Parameters (sanitized here — real values on the servers)

| Placeholder | Where the real value lives |
|---|---|
| `<RELAY_IP>` | DNS A-record of the relay / any relay shell |
| `<MAIN_IP>` | DNS A-record of flexchat.top / any main shell |
| `<PHONE_UUID>` | relay: `/usr/local/etc/xray/config.json` → inbounds.clients[0].id |
| `<PHONE_SHORT_ID>` | relay: same file → inbounds.realitySettings.shortIds[0] |
| `<PHONE_PUBLIC_KEY>` | derived from relay privateKey (see keygen below); stored in phone client |
| `<RELAY_PRIVATE_KEY>` | relay: same file → inbounds.realitySettings.privateKey |
| `<EXIT_UUID>` | main: `/usr/local/etc/xray/config.json` → inbounds.clients[0].id |
| `<EXIT_SHORT_ID>` | main: same file → shortIds[0] (matches bridge config on relay) |
| `<EXIT_PRIVATE_KEY>` | main: same file → privateKey |
| `<EXIT_PUBLIC_KEY>` | main: same file → derive via openssl; stored in relay: `/etc/sing-box/config.json` |

Camouflage: relay inbound dest/SNI `kz-ala-1.blook.network:443`; main inbound dest/SNI `flexchat.top:443` (itself — must be reachable **from main**; `kz-ala-1.blook.network` is not, hence the switch).

## Rebuild procedure

1. Install binaries:
   - xray: latest from `https://github.com/XTLS/Xray-core/releases` (verify zip size — wrong repo 404s into a tiny broken zip).
   - sing-box 1.12.x on relay (any ≥1.12 works for this bridge).
2. Generate a fresh REALITY keypair **on the target server**:
   - `xray x25519` prints private + public key.
   - Gotcha: on 25.12.8 `xray x25519 -i <priv>` prints "Password/Hash32", not the plain public key. Derive the public key with openssl instead:
     `openssl pkey -in <(echo '-----BEGIN PRIVATE KEY-----'; xray x25519 | awk '/Private/{print $2}' | base64 -d | base64 -w0; printf '\n-----END PRIVATE KEY-----\n') -pubout | grep -v -- '---' | base64 | tr -d '=\n'`
3. Fill the placeholders in the configs, copy to the paths above, `systemctl daemon-reload && systemctl enable --now xray sing-box-client` (relay) / `xray-main` (main).
4. Relay routing rule: `{"type":"field","ip":["<RELAY_IP>"],"outboundTag":"direct"}` keeps Nextcloud local. Main routing rule pins its own IP to `direct` (loop protection).
5. Firewall: relay open 80,443 (8000 for batch-chat when applicable); main open 22,443,39443,8000.

## E2E tests

```bash
# hop 1: relay bridge → main exit (expect MAIN_IP)
curl -s --socks5-hostname <RELAY_IP-side localhost>:10809 https://api.ipify.org   # on relay
ssh relay 'curl -s --socks5-hostname 127.0.0.1:10809 --max-time 12 https://api.ipify.org'

# full chain: temp vless client on relay (socks :10808) pointed at relay:443 with PHONE_* params
# config recipe in scripts/e2e-test.sh comments; expect exit MAIN_IP and flexchat.top/health = 200
./scripts/e2e-test.sh
```

## Gotchas (learned the hard way)

- **xray 25.12.8 client REALITY is incompatible with both sing-box 1.14 server AND xray 26.3.27 server** ("invalid connection" / "failed to read client hello") — 25.12 introduced a post-quantum ClientHello. That's why the relay bridge hop is **sing-box**, not a second xray hop. sing-box client → xray 26.3.27 server works fine.
- **Main server has no IPv6** (`curl -6` exit 6): exit outbound needs `"domainStrategy": "UseIPv4"`, and always `curl -4` from it.
- REALITY dest must be reachable **from the exit server**; test with `openssl s_client -connect <dest> -servername <sni>` from there. If dest is unreachable, xray serves its own fallback cert (issuer `YE1` — a tell-tale in `openssl s_client` output).
- Debug order for a silent chain: bump `loglevel` to `info` on every xray instance → watch client log, relay journal, main journal. "accepted tcp:… [to-main]" on relay + nothing on main = hop-2 problem.
- If the temp-client socks test needs a kill: `ss -tlnp | grep 10808` → kill that pid (never `pkill -f xray` — can kill your own ssh).
