# Extension Phase 0: baseline and safety net

**Date:** 8 October 2026. **Commit:** `3197fca`. **State:** done. Design context: [08-extension-design.md](08-extension-design.md).

## Goal

Before building anything new, make every later change visible, reviewable and reversible,
and remove a hidden weakness of a lab cloned from one disk image.

## Why

| Need | Answer |
|---|---|
| Change control | Each phase becomes a commit; `git diff` shows exactly what it changed |
| Rollback | Any earlier version of any configuration file can be recovered |
| Rebuild documentation | The restore drill (Extension Phase 5) can rebuild a node from the repository |
| Cloned identities | Nodes cloned from one image may share SSH host keys (one server could impersonate another) and machine-ids (two hosts could get the same DHCP lease) |

**Rule: no secret in Git.** A secret committed once stays in the history for ever. The
repository holds sanitised copies; the real secrets stay on the nodes until Vault (Extension Phase 4).

## What was done

### 1. Host identity check

On every Ubuntu node, the ED25519 host key fingerprint and the machine-id were compared.
No duplicates were found (reported). The fingerprints of the three servers were also shown
by `scp` during step 4 and are recorded in [../inventory/host-identities.md](../inventory/host-identities.md):

| Server | Host key (SHA256) |
|---|---|
| AppServer 172.16.0.10 | `3q8re8pgfcEnn4hNU2wqFzoXajY3X/GhyOHvgeQF1H8` |
| RADIUS1 172.16.0.20 | `1u207+dI8rKSCY1/mLEhOjg5TE17Y2/RbbvUyK4i2DY` |
| LOG1 10.10.30.20 | `WGBLnV2SMkUVag9TEHRqJTKvcL/zifD1/yBFMDXnCss` |

### 2. Repository

Created on Windows at `C:\Users\moadh\Documents\ztna-lab-config`:

- `.gitattributes` (`* text=auto eol=lf`): files go back to Linux, where CRLF line endings break scripts.
- `.gitignore`: `*.key`, `*.env`, `.env`, `*.tgz`, `incoming/`, `*.p12`, `*.pfx`, as a second line of defence.
- Folders `nodes/`, `inventory/` and `incoming/` (downloads, never tracked).

### 3. Export script on AppServer, RADIUS1 and LOG1

`/usr/local/sbin/ztna-config-export` (copy in [../scripts/ztna-config-export](../scripts/ztna-config-export))
reads `/etc/ztna-export.list` and produces a sanitised archive:

| Step | Effect |
|---|---|
| Copy | Each listed path, with permissions, into a private temporary folder |
| Drop | `.env` files, backup copies, and any file containing a private key |
| Record | `PERMISSIONS.txt` (mode, owner, group) and `SYMLINKS.txt`, which Windows cannot store |
| Redact | FreeRADIUS `secret =`, `Crypt-Password`, `TOTP-Secret`, `client_secret`, `…_PASSWORD` and `…_SECRET` values; compose references such as `${DB_PASSWORD}` are kept |
| Fail-safe | No archive at all if a private key or a crypt hash is still found |

The same script is reused in Extension Phase 5 as the forced command of the automated backup job.

**Exported paths:**

| Node | Paths |
|---|---|
| AppServer | compose project, nginx, `/etc/ssl/ztna`, rsyslog, sshd drop-ins, ufw rules, chrony, netplan, hostname, hosts |
| RADIUS1 | `/etc/freeradius/3.0`, `ztna-radius-passwd`, rsyslog, sshd drop-ins, ufw rules, chrony, netplan, hostname, hosts |
| LOG1 | rsyslog, both logrotate rules, detection and digest units and scripts, lnav files, `.bashrc`, sshd drop-ins, ufw rules, chrony, netplan, hostname, hosts |

### 4. Transfer to Windows (temporary path)

- A dedicated Windows key `phase0-export` (ED25519, with a passphrase) was added to
  labadmin's `authorized_keys` on the three servers, restricted to `from="10.10.50.49"`
  (the itadmin VPN address).
- The OpenVPN server pushes an extra route to LOG1 (`10.10.30.20/32`).
- Windows connected to the VPN as itadmin and copied the archives with `scp`.

Both are **temporary exceptions**, closed in Extension Phase 3.

### 5. pfSense configuration

- Encrypted full backup saved outside Git (it contains the CA private key).
- Redacted readable copy at `nodes/fw1/config-redacted.xml`: `prv`, `tls`, `radius_secret`,
  `bcrypt-hash`, `xmldata` and `password` elements replaced by `REDACTED`. A check counted
  0 unredacted elements before download.

### 6. Review, commit and publication

- Secret scan over `nodes/` before committing: no private key, no crypt hash.
- First commit `3197fca`, 329 files.
- Published as the **private** GitHub repository `ztna-lab-config`. Private because, even
  sanitised, the files describe the whole internal design.

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| The export on RADIUS1 stopped with `ABORT: secret material left` on `ztna-radius-passwd` | The fail-safe matched the bare prefix `$6$`, which the script mentions to check `mkpasswd` output; it holds no hash | The check now requires at least 8 salt characters after the prefix. Proven both ways: 0 matches in the script, 5 matches in the real users file. |
| `scp` to AppServer and LOG1: `Permission denied (publickey)` without a passphrase prompt | The restricted key line was missing or malformed on those two servers (RADIUS1 worked, so the path was fine) | Line rewritten with `read -r k; printf 'from="10.10.50.49" %s\n' "$k" >> …`, which cannot produce a malformed line |
| The secret scan on Windows listed harmless lines ending in `\` | PowerShell expands `$6`, `$y` and `$2b` inside double quotes, so the pattern Git received was wrong | Single quotes, and the same stricter pattern as the export script |

## Result

| Item | Evidence |
|---|---|
| Repository with sanitised configuration of FW1, AppServer, RADIUS1, LOG1 | **Verified** (commit `3197fca`, pushed) |
| No secret committed | **Verified** by scanning the committed files |
| Three distinct server fingerprints | **Verified** |
| No duplicate identity on the other nodes | Reported |
| Encrypted pfSense backup outside Git | Reported |
