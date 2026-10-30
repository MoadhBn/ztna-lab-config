# Extension Phase 2B, part 1: RADIUS1 and LOG1 behind Warpgate, session approval

**Date:** 30 October 2026. **Commit:** the commit that adds this file. **State:** done.
Previous part: [11-ext-phase-2a-warpgate.md](11-ext-phase-2a-warpgate.md).

Extension Phase 2B is split in two. **Part 1** (this file) adds the two other servers as SSH
targets, a separate approver identity and per-session approval for RADIUS1, and evaluates
access tickets. **Part 2** adds the web targets (pfSense GUI and Keycloak `/admin`), which
need their own design: Keycloak redirects the browser to its configured hostname
(`KC_HOSTNAME`), and pfSense refuses pages reached under another name (DNS rebinding and
HTTP_REFERER checks).

## Goal

Every server holding identity or evidence is reachable for administration through Warpgate,
and the identity crown jewel, RADIUS1, needs a second person's approval for each session.

```text
itadmin ──► Warpgate (PAM1) ──┬─► appserver  172.16.0.10   role ops
  (Keycloak + OTP)            ├─► log1       10.10.30.20   role ops
                              └─► radius1    172.16.0.20   role ops + approval by secops
secops ──► Warpgate admin UI: approve or reject only        (Keycloak group pam-approvers)
```

## Design decisions

| Decision | Reason |
|---|---|
| Approval required on `radius1` only | RADIUS1 decides who joins the VPN and the firewall GUI; AppServer and LOG1 keep the faster path, still recorded |
| No approval cache period | An approval covers one session and is never reused |
| The approver is a separate person, `secops`, in the Keycloak group `pam-approvers` | The requester cannot approve their own session; the local Warpgate `admin` stays break-glass and is not used every day |
| Group mapped to the Warpgate admin role `approver` at login (`admin_roles_claim`, `admin_role_mappings`) | Approval rights follow Keycloak group membership, like the `ops` role; no Warpgate-only privilege to maintain |
| `approver` has only *Sessions → View* and *Sessions → Approve*, and `secops` has no access role | The approver cannot open sessions on servers, change targets, users or roles, view recordings or terminate sessions |
| Full passwordless sudo for `pamops` on RADIUS1 and LOG1, as on AppServer | A command allow-list for an administrator is not a boundary (any command that edits a file leads to root). The controls are who may open the session (role, approval) and what is recorded (Warpgate recording and command log, sudo log on LOG1). The standing key goes in Extension Phase 4 |
| Access tickets not used for people | Tested: a ticket opens a shell without Keycloak and without OTP, i.e. a second login system, against the project's rule. Users cannot request tickets |

## What was done

### FW1

| Item | Value | Evidence |
|---|---|---|
| SEC rule `PAM1 brokered SSH (PAM_SSH_TARGETS)` | `PAM_SERVER → PAM_SSH_TARGETS:22` (AppServer, RADIUS1, LOG1), logged; was `APP_SERVER` only | **Verified** in `nodes/fw1/config-redacted.xml` |

PAM1 → LOG1 crosses FW1 from SEC to IT. pfSense filters on the incoming interface, so only
the SEC rule is needed.

### PAM1

| Item | Value |
|---|---|
| Netplan | Installer file `00-installer-config.yaml` removed (moved to `/root`); the merged configuration is static only, `dhcp6` no longer present |
| `warpgate.yaml` | `admin_roles_claim: groups`, `admin_role_mappings: pam-approvers → approver` |
| Warpgate database | Copied to `/root/warpgate-db-before-2b` (service stopped during the copy) before the changes |

### RADIUS1 and LOG1 (same on both)

| Item | Value |
|---|---|
| Account `pamops` | Created with `useradd`, password locked (`passwd -S`: `L`) |
| `authorized_keys` | Warpgate's ed25519 key with `from="10.10.60.10"`, fingerprint `ZyENO54SVtc/gM0crh22i8NtDICSDjCvlFL4SQhw4u0` |
| sudo | `/etc/sudoers.d/90-pamops`, checked with `visudo -cf` before installation, mode 440 |
| ufw | 22 from `10.10.60.10`, comment "SSH from PAM1 (Warpgate)" |
| Export list | `90-pamops` and `pamops`'s `authorized_keys` added |
| labadmin `authorized_keys` | Dead `phase0-export` line removed, `ztna-export` added with `from="10.10.50.49"` |

### Keycloak (realm `ztna`)

| Item | Value |
|---|---|
| Group | `pam-approvers` |
| User | `secops@ztna.lab`, e-mail verified, OTP configured at first login, member of `pam-approvers` only |

### Warpgate

| Object | Value |
|---|---|
| Target `radius1` | SSH `172.16.0.20:22`, user `pamops`, ed25519 key, role `ops`, *Require administrator approval for each connection* |
| Target `log1` | SSH `10.10.30.20:22`, user `pamops`, ed25519 key, role `ops` |
| Admin role `approver` | *Sessions → View*, *Sessions → Approve*; nothing else |
| User `secops` | SSO credential `secops@ztna.lab`, no access role; `approver` assigned by the login mapping |
| Session approvals | Admin approval cache period empty |
| Tickets | *Allow users to request tickets* off |

## Tests

| # | Test | Expected | Evidence |
|---|---|---|---|
| 1 | Host keys of RADIUS1 and LOG1 read from PAM1 (`ssh-keyscan`) | Inventory values | **Verified**: `1u207+dI8rKSCY1/mLEhOjg5TE17Y2/RbbvUyK4i2DY`, `WGBLnV2SMkUVag9TEHRqJTKvcL/zifD1/yBFMDXnCss` |
| 2 | PAM1 network configuration | Static, no DHCP | **Verified** (`netplan get ethernets.ens3`) |
| 3 | `secops` logs in through Keycloak | Admin UI with the approver functions only | **Verified**: the admin approvals endpoint answers `200` for `secops`; the requests page shows Approve and Reject |
| T1 | `itadmin` opens `radius1` | Waits; request visible to `secops` | **Verified**: "Waiting for an administrator to approve this session…"; `secops` sees "itadmin is connecting to radius1, 10.10.50.49" |
| T2 | `secops` approves | Shell opens | **Verified**: `pamops@radius1`, `id` → `uid=1001(pamops)`; LOG1: `radius1 sshd-session … Accepted publickey for pamops from 10.10.60.10 … ZyENO54S…` (20:16:33) |
| T3 | `itadmin` again, `secops` rejects | Refused, no login on the server | **Verified**: "An administrator did not approve this session."; Warpgate: `kind=Admin resolved_by=secops approved=false`, `Session was refused by an administrator` (20:16:57); no new RADIUS1 login on LOG1 |
| T4 | `itadmin` opens `log1` | Opens without approval | **Verified**: LOG1 `log1 sshd-session … Accepted publickey for pamops from 10.10.60.10` (19:28:45, 19:28:56, 19:29:35) |
| T5 | `itadmin` opens `/@warpgate/admin` | No admin access | **Verified**: the page is served but no admin API call is made; the page reloads (see Problems) |
| T6 | `secops` opens a target | Not possible (no access role) | Reported |
| T7 | Replay of the T2 session | Shows `id` and its output | **Verified** (replay as `admin`, 8 s) |
| 8 | sudo through Warpgate on RADIUS1 | Logged on LOG1 | **Verified**: `radius1 sudo: pamops : TTY=/dev/pts/0 ; … COMMAND=/usr/bin/true` (19:28:00) |
| 9 | FW1 lets PAM1 reach the new targets | Pass lines | **Verified**: `vtnet6,match,pass … 10.10.60.10,172.16.0.20,…,22` (19:27:34) and `10.10.60.10,10.10.30.20,…,22` (19:28:56, 19:29:35), rule tracker `1792846784` = `PAM1 brokered SSH (PAM_SSH_TARGETS)` |
| 10 | `ssh -l pamops 172.16.0.20` and `10.10.30.20` from IT1 | `Permission denied (publickey)` | **Verified** |
| 11 | Ticket for `itadmin` → `log1`, 1 use, about 15 minutes | First use opens a shell without Keycloak or OTP; second use refused | **Verified**: shell on `pamops@log1` (LOG1 login 19:42:22); then the ticket shows "Used up" and a second attempt only gets a password prompt |

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| The Warpgate page reloaded in a loop (also the unexplained loop of 2A) | The admin UI (`/@warpgate/admin`) was open in a browser whose login had become `itadmin`'s. Warpgate keeps one login per browser, shared by all InPrivate windows; v0.30.0 serves the admin page to a non-admin user and the page reloads instead of refusing. Found in the Warpgate log: `session_username=itadmin … url=/@warpgate/admin` repeating | Go to `/@warpgate`. Rule: one identity per browser context (Edge normal: `itadmin`; Edge InPrivate: `secops`; second browser: `admin`) |
| `ztna-config-export` on PAM1: `Cannot open: Permission denied` | The 2A archive with the same name was still in `/tmp`, owned by labadmin. With `fs.protected_regular`, the kernel refuses root opening another user's existing file in a sticky world-writable directory | Old archive removed, export run again. The script will remove an existing archive before writing (Extension Phase 5, when it becomes the backup job) |
| The new encrypted FW1 backup was saved as `nodes/fw1/backup.xml` | The ignore rule only matched `nodes/fw1/config-*` | Moved to `C:\ztna-backups\config-fw1.ztna.lab-20261030200400.xml`; `.gitignore` now ignores everything in `nodes/fw1/` except `config-redacted.xml` |
| The method used to produce the redacted FW1 copy was not recorded | — | Recorded below |

### Redacted FW1 copy

In pfSense, *Diagnostics → Command Prompt*:

```text
sed -E 's#<(prv|tls|radius_secret|bcrypt-hash|xmldata|password)>(<!\[CDATA\[[^]]*\]\]>|[^<]*)</(prv|tls|radius_secret|bcrypt-hash|xmldata|password)>#<\1>REDACTED</\1>#g' /conf/config.xml > /tmp/config-redacted.xml
grep -E '<(prv|tls|radius_secret|bcrypt-hash|xmldata|password)>' /tmp/config-redacted.xml | grep -vc REDACTED   # must print 0
```

Then *Download File* `/tmp/config-redacted.xml` and `rm /tmp/config-redacted.xml`. On Windows
the file was checked again (15 `REDACTED` elements, no private key, no hash; the remaining
base64 blocks are certificates and the CRL) before replacing `nodes/fw1/config-redacted.xml`.

## Findings

- **A ticket login is indistinguishable on the server.** The ticket session of test 11 appears
  on LOG1 exactly like a Keycloak-authenticated one (`pamops` from `10.10.60.10`, same key).
  Only Warpgate knows which identity and which method were used, so Warpgate's own audit log
  must reach LOG1 (Extension Phase 6).
- **Warpgate's audit log names the approver.** The refusal is logged with `resolved_by=secops`
  and `approved=false`; this is the line to forward and alert on.
- **pfSense changes are made with the local `admin` account.** The FW1 change history shows
  `admin@192.168.78.1 (Local Database Fallback)`, so the break-glass account is the daily one.
  Part 2 moves pfSense administration to the RADIUS identity through Warpgate.
- **OpenVPN profiles in `Downloads`.** Five exported `.ovpn` files embed each user's private
  key; to delete once imported into the OpenVPN client (with the other clean-ups of Extension
  Phase 3).
- Command logging remains a heuristic aid: Warpgate itself describes it as not a security
  boundary. The recording is the reliable record.

## Still open

- Part 2: web targets (pfSense GUI with its RADIUS login, Keycloak admin console).
- T6 is reported, not shown: `secops` has no access role, so Warpgate lists no target for them.
