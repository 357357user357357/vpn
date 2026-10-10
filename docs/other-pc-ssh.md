# Connect to the servers from another PC

> **Passwords are intentionally NOT stored in this repo** (it is pushed to
> GitHub). Ask the owner for the passwords out-of-band, or — better — use
> SSH keys (below). The same rule applies to every script here: hosts may
> have env-var defaults, secrets never live in git.

## Servers

- Russian relay (readystart.fvds.ru): `62.109.10.170`, user `root`
- Turkey main (flexchat.top): `166.1.2.48`, user `root`

Password SSH login is enabled on both (fixed 2026-10-08 on BOTH servers:
the hosting's `/etc/ssh/sshd_config.d/00-hardening.conf` had
`PasswordAuthentication no` + `PermitRootLogin prohibit-password`, which
won over the later drop-ins because OpenSSH takes the FIRST match; on
each server the file is now `yes`/`yes` with backup `00-hardening.conf.bak`).

## To-do (Linux / macOS)

```bash
export BC_RELAY=62.109.10.170 BC_MAIN=166.1.2.48
ssh root@"$BC_RELAY"   # enter password when prompted (ask owner)
ssh root@"$BC_MAIN"
```

## To-do (Windows)

Use PuTTY or `ssh` in PowerShell with the same host/user; the password is
not published here.

## Recommended: key login (no password at all)

Generate a key on the new PC and install it on both servers:

```bash
ssh-keygen -t ed25519
ssh-copy-id root@"$BC_RELAY"
ssh-copy-id root@"$BC_MAIN"
```

After this the password is not needed from that PC at all.

## One-liner that skips typing the password (scripts)

Keep the password in an environment variable or a root-only file, never in
a script committed to git:

```bash
export BC_RELAY_PW='...'          # set once per shell, from the owner
sshpass -p "$BC_RELAY_PW" ssh root@"$BC_RELAY" '<command>'
```

(`apt install sshpass` first; on the relay itself sshpass is not installed.)

## Notes

- Fail2ban is NOT installed on the relay; root+password is brute-forced
  constantly (check `journalctl -u ssh`). Keys are installed for the main
  laptop; prefer keys, keep the password as backup.
- The relay's sshd drop-ins: `00-hardening.conf` wins over `40-hosting.conf`
  (OpenSSH takes the FIRST value). Backup: `00-hardening.conf.bak`.
- `bc-ssh` (in `~/bin` on the main laptop) wraps SSH to Turkey via the relay.
- **If a password ever lands in git history, rotate it** — rewriting history
  does not un-leak it (clones/forks may exist).
