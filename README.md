# vpn

VPN-style forwarding chain: RU relay → foreign exit on the main server. Phone/PC clients connect to the **relay** (existing config, unchanged); all traffic except Nextcloud exits through the **main server**.

Repos are kept **public — all secrets are sanitized**. Real values live only on the servers (paths listed below).
Camouflage domains are placeholders here (the relay camo domain is fictional); the main server's own SNI `flexchat.top` is a real public service name, shown intentionally — real VPN values live server-side only.

## Topology

```
phone / PC (vless+REALITY client, params unchanged)
   │
   ▼
RU relay (<RELAY_IP>) — xray :443  [phone-facing inbound, vless+REALITY]
   │  routing: <RELAY_IP> → direct (Nextcloud local/fast)
   │           RU sites (geosite:category-ru / geoip:ru) → direct (RU speed)
   │           everything else → outbound "to-main"
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

The RU relay is a temporary, cost-driven hop — see Migration runbooks below for replacing or dropping it.

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
| `<MAIN_IP>` | any main shell (no public-DNS linkage documented here on purpose) |
| `<PHONE_UUID>` | relay: `/usr/local/etc/xray/config.json` → inbounds.clients[0].id |
| `<PHONE_SHORT_ID>` | relay: same file → inbounds.realitySettings.shortIds[0] |
| `<PHONE_PUBLIC_KEY>` | derived from relay privateKey (see keygen below); stored in phone client |
| `<RELAY_PRIVATE_KEY>` | relay: same file → inbounds.realitySettings.privateKey |
| `<EXIT_UUID>` | main: `/usr/local/etc/xray/config.json` → inbounds.clients[0].id |
| `<EXIT_SHORT_ID>` | main: same file → shortIds[0] (matches bridge config on relay) |
| `<EXIT_PRIVATE_KEY>` | main: same file → privateKey |
| `<EXIT_PUBLIC_KEY>` | main: same file → derive via openssl; stored in relay: `/etc/sing-box/config.json` |

Camouflage: relay inbound dest/SNI `<CAMO_RELAY_DOMAIN>:443` (placeholder); main inbound dest/SNI `flexchat.top:443` (itself — must be reachable **from main**; the relay camo domain is not, hence the switch).

## Rebuild procedure

1. Install binaries:
   - xray: latest from `https://github.com/XTLS/Xray-core/releases` (verify zip size — wrong repo 404s into a tiny broken zip).
   - sing-box 1.12.x on relay (any ≥1.12 works for this bridge).
2. Generate a fresh REALITY keypair **on the target server**:
   - `xray x25519` prints private + public key (URLSAFE base64, no padding).
   - Gotcha: on 25.12.8 `xray x25519 -i <priv>` prints "Password/Hash32", not
     the plain public key. Derive it reliably from the private key (Python,
     verified 2026-09-19 — the private key is the 32-byte x25519 seed; wrap it
     in a PKCS8 PEM, let openssl export the SPKI, take the last 32 bytes):
     ```bash
     python3 - <<'PY'
     import base64, subprocess
     priv = "<RELAY_PRIVATE_KEY>"  # 43-char urlsafe b64 from xray x25519
     raw = base64.urlsafe_b64decode(priv + "=" * (-len(priv) % 4))
     der = bytes.fromhex("302e020100300506032b656e04220420") + raw
     open("/tmp/k.pem", "w").write("-----BEGIN PRIVATE KEY-----\n"
         + base64.encodebytes(der).decode() + "-----END PRIVATE KEY-----\n")
     spki = subprocess.run(["openssl", "pkey", "-in", "/tmp/k.pem",
                            "-pubout", "-outform", "DER"],
                           capture_output=True).stdout
     print(base64.urlsafe_b64encode(spki[-32:]).decode().rstrip("="))
     PY
     ```
3. Fill the placeholders in the configs, copy to the paths above, `systemctl daemon-reload && systemctl enable --now xray sing-box-client` (relay) / `xray-main` (main).
4. Relay routing rule: `{"type":"field","ip":["<RELAY_IP>"],"outboundTag":"direct"}` keeps Nextcloud local. Main routing rule pins its own IP to `direct` (loop protection).
5. Firewall: relay open 80,443 (8000 for batch-chat when applicable); main open 22,443,39443,8000.

## Split routing — Russian sites go direct (added 2026-09-19)

Requirement: at work abroad-networks, foreign sites are blocked while Russian
addresses work — so the phone connects to the relay and the relay sends
**Russian traffic out with its own (RU) IP**, while everything else rides the
chain and exits as `<MAIN_IP>` (secure-VPN behavior for the blocked part).

Relay `routing` (geoip/geosite data lives in `/usr/local/share/xray/`):

```json
"domainStrategy": "IPIfNonMatch",
"rules": [
  {"type": "field", "ip": ["<RELAY_IP>"], "outboundTag": "direct"},
  {"type": "field", "domain": ["geosite:category-ru"], "outboundTag": "direct"},
  {"type": "field", "ip": ["geoip:ru", "geoip:private"], "outboundTag": "direct"}
]
```

- `geosite:category-ru` matches Russian domains; `IPIfNonMatch` then resolves
  unmatched domains so `geoip:ru` catches RU-hosted IPs too. `geoip:private`
  keeps LAN traffic direct.
- **OpenRouter pin (2026-10-05):** `domain:openrouter.ai → to-main` sits as the
  **first** rule so OpenRouter always exits as `<MAIN_IP>` and never via the RU
  IP — its WAF 403s RU-range clients. Verified live: during chain requests to
  openrouter.ai the relay contacts only the tunnel peer (no direct openrouter
  IPs), while ya.ru still goes direct; relay-side DNS for openrouter.ai returns
  bogus A records, which is why the pin matches by SNI/domain, not IP.
- Deploy: edit the relay's `/usr/local/etc/xray/config.json` the same way,
  `xray run -test -c /usr/local/etc/xray/config.json`, then
  `systemctl restart xray`.
- Verify through the full chain (temp vless client from `e2e-test.sh`):
  `curl --socks5-hostname 127.0.0.1:10808 https://2ip.ru` → `<RELAY_IP>` (RU
  site, direct) while `curl --socks5-hostname 127.0.0.1:10808
  https://api.ipify.org` → `<MAIN_IP>` (foreign site, via the exit).

## Mobile browser / other apps

The phone's vless+REALITY client (v2rayNG, Hiddify, …) runs as a **system-wide
VPN**, so every app — Chrome, Firefox, whatever — automatically rides the
chain with the split rules above; no per-app setup or extra proxy port needed.
Desktop browsers work the same through the PC client.

## E2E tests

```bash
# hop 1: relay bridge → main exit (expect MAIN_IP)
curl -s --socks5-hostname 127.0.0.1:10809 --max-time 12 https://api.ipify.org    # (run on the relay)
ssh relay 'curl -s --socks5-hostname 127.0.0.1:10809 --max-time 12 https://api.ipify.org'

# full chain: temp vless client on relay (socks :10808) pointed at relay:443 with PHONE_* params
# config recipe in scripts/e2e-test.sh comments; expect exit MAIN_IP and flexchat.top/health = 200
./scripts/e2e-test.sh
```

`EXPECTED_EXIT_IP=<MAIN_IP> ./scripts/e2e-test.sh` makes the script assert the real exit IP;
the sanitized default matches nothing on purpose.

## Migration runbooks

### A. Moving the foreign exit to a new main

1. Provision the new main: xray + `xray-main` unit (see Rebuild procedure); firewall open 22,443,39443,8000.
2. Fresh keys **on the new host**: `xray x25519` → `<NEW_EXIT_PUBLIC_KEY>` + a new short_id (fill the main config; real values server-side).
3. Fill `main/xray-config.json`; keep the loop-protection rule pinned to the new main's own IP.
4. Pre-flight **from the new host** — camo dest must present the real cert:
   `openssl s_client -connect flexchat.top:443 -servername flexchat.top` (fallback-issuer tell-tale `YE1`, see Gotchas).
5. DNS: drop the A-record TTL well in advance.
6. Cutover: move the A-record → `<NEW_MAIN_IP>`; update relay `sing-box-client.json` outbound (`server`/`public_key`/`short_id`) and `systemctl restart sing-box-client`.
7. Verify: `EXPECTED_EXIT_IP=<NEW_MAIN_IP> ./scripts/e2e-test.sh`.
8. Rollback: repoint sing-box at the old main and restart. Decommission the old main **last**.
   Phone/PC clients need zero changes — they only ever talk to the relay.

### B. Replacing the temporary RU relay

1. Provision the new relay: xray + `sing-box-client` (see Rebuild procedure); geo data in `/usr/local/share/xray/`; firewall open 80,443 (8000 when applicable).
2. Fresh relay REALITY keypair + short_id → `<PHONE_PUBLIC_KEY>` (keygen above), `<PHONE_UUID>`, `<PHONE_SHORT_ID>`, `<CAMO_RELAY_DOMAIN>`.
3. **Client-facing event:** every phone/PC client re-imports the vless profile.
4. Update relay config: direct-rule IP → `<NEW_RELAY_IP>`, geosite/geoip data, firewall, relay DNS A-record.
5. Verify: `EXPECTED_EXIT_IP=<MAIN_IP> ./scripts/e2e-test.sh root@<NEW_RELAY_IP> root@<MAIN_IP>` (drop the temp-client json on the new relay first).
6. Decommission the old relay **last**.

### C. Dropping the relay later

Clients aim straight at the main: `<MAIN_IP>:39443`, vless+REALITY with the `EXIT_*` parameters
(`uuid=<EXIT_UUID>`, `sid=<EXIT_SHORT_ID>`, `pbk=<EXIT_PUBLIC_KEY>`, SNI flexchat.top). One profile
re-import per client; the RU-direct split routing no longer applies (everything exits foreign).

## Gotchas (learned the hard way)

- **xray 25.12.8 client REALITY is incompatible with both sing-box 1.14 server AND xray 26.3.27 server** ("invalid connection" / "failed to read client hello") — 25.12 introduced a post-quantum ClientHello. That's why the relay bridge hop is **sing-box**, not a second xray hop. sing-box client → xray 26.3.27 server works fine.
- **Main server has no IPv6** (`curl -6` exit 6): exit outbound needs `"domainStrategy": "UseIPv4"`, and always `curl -4` from it.
- REALITY dest must be reachable **from the exit server**; test with `openssl s_client -connect <dest> -servername <sni>` from there. If dest is unreachable, xray serves its own fallback cert (issuer `YE1` — a tell-tale in `openssl s_client` output).
- Debug order for a silent chain: bump `loglevel` to `info` on every xray instance → watch client log, relay journal, main journal. "accepted tcp:… [to-main]" on relay + nothing on main = hop-2 problem.
- If the temp-client socks test needs a kill: `ss -tlnp | grep 10808` → kill that pid (never `pkill -f xray` — can kill your own ssh).
