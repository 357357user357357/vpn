# Connect to the servers from another PC

## Servers

- Russian relay (readystart.fvds.ru): `62.109.10.170`, user `root`, password `kn49kn`
- Turkey main (flexchat.top): `166.1.2.48`, user `root`, password `kn49kn49`

Password SSH login is enabled on both (relay fixed 2026-10-08: hosting's
`/etc/ssh/sshd_config.d/00-hardening.conf` had `PasswordAuthentication no`
+ `PermitRootLogin prohibit-password` which won over the later drop-in;
both are now `yes`).

## To-do (Linux / macOS)

```bash
ssh root@62.109.10.170        # password: kn49kn
ssh root@166.1.2.48           # password: kn49kn49
```

## To-do (Windows)

Use PuTTY or `ssh` in PowerShell with the same host/user/password.

## Optional: key login (no password prompts)

Copy this laptop's key to the other PC, then it works without a password:

```bash
scp ~/.ssh/id_ed25519* otherpc:~/.ssh/    # or generate a new key there
ssh-copy-id root@62.109.10.170
ssh-copy-id root@166.1.2.48
```

## One-liner that skips typing the password (scripts)

```bash
sshpass -p kn49kn ssh root@62.109.10.170 '<command>'
```

(`apt install sshpass` first; on the relay itself sshpass is not installed.)

## Notes

- Fail2ban is NOT installed on the relay; root+password is brute-forced
  constantly (check `journalctl -u ssh`). Keys are installed for the main
  laptop; prefer keys, keep the password as backup.
- The relay's sshd drop-ins: `00-hardening.conf` wins over `40-hosting.conf`
  (OpenSSH takes the FIRST value). Backup: `00-hardening.conf.bak`.
- `bc-ssh` (in `~/bin` on the main laptop) wraps SSH to Turkey via the relay.
