# Phase 6: visibility, logging, detection and host hardening

**Period:** weeks 4–5. **State:** built (parts A–E); attack scenarios and backups moved to
the extension.

## Goal

Zero Trust assumes an attacker may already be inside, so attempts must be observed as well
as blocked. This phase adds one reliable timeline of every decision, investigation views,
detection rules, and the host-level controls that filter traffic FW1 never sees.

## Parts

| Part | Content | Evidence |
|---|---|---|
| A | LOG1 node (IT, 512 MB, 10.10.30.20, serial) | Done |
| B | Collector and log rotation | **Verified** (archives present) |
| C | Sources: FW1, RADIUS1, AppServer | **Verified** (lines from each seen on LOG1) |
| E-pre | Logging format upgrade (two timestamps, RFC 5424 senders) | **Verified** |
| D1 | ufw on AppServer, RADIUS1, LOG1 | Rules **verified**; regression and denial tests reported |
| D2 | Keycloak named administrator with OTP | Done |
| – | lnav format and views | Reported |
| E | Detection R1–R7 and daily digest | Installed; R1–R6 triggers reported; R7 not confirmed |
| F | Attack scenarios S1–S15 | Moved to Extension Phase 9 |
| G | Encrypted backups and log hashing | Moved to Extension Phase 5 |

## Time synchronisation

TOTP (30-second steps), certificates and log correlation all need one accurate time.

| Element | Configuration |
|---|---|
| EVE-NG VM | open-vm-tools time sync with the host; chrony as the lab time server (`local stratum 8`, `allow 192.168.78.0/24`, pools commented) |
| FW1 | ntpd, server 192.168.78.10 only, orphan mode off (stratum 9); Service Watchdog restarts ntpd |
| Nodes | chrony: `server 192.168.78.10 iburst minpoll 4 maxpoll 6`, `makestep 1 -1`, `rtcsync`; htpdate and timesyncd removed |

**Why nodes do not sync to FW1:** after a VM pause FW1 resumes behind; ntpd refuses
corrections above 1000 s and exits, while the EVE-NG VM is corrected at once by VMware
Tools. Measured: LOG1 +109 µs, Reach 377; FW1 `sync_ntp`, offset −0.32 ms, frequency
−0.132 ppm (**verified**).

## Collector (LOG1)

- rsyslog receives UDP and TCP 514 into a dedicated ruleset.
- Each line holds **two timestamps**: the event time from the sender and the reception
  time on LOG1 (`rcv=`). Delayed delivery keeps the true timeline, and the difference
  reveals a sender with a wrong clock.
- Every line goes to `/var/log/ztna/all.log` and to `/var/log/ztna/<host>/<program>.log`.
  Host and program names are sanitised (`secpath-replace`), so a forged message cannot
  write outside the directory.
- Directory `syslog:adm 0750`, files 0640; `labadmin` reads them through the `adm` group.
- `/etc/logrotate.d/ztna`: daily, 14 rotations, delayed compression, HUP to rsyslog.

Example lines (**verified**):

```text
2026-10-05T17:54:57.758861+01:00 rcv=2026-10-05T17:54:57.761980+01:00 appserver kernel [UFW BLOCK] IN=ens3 ... SRC=172.16.0.20 DST=172.16.0.10 ... PROTO=TCP SPT=56904 DPT=22 ...
2026-10-05T17:49:42.488122+01:00 rcv=2026-10-05T17:49:42.491165+01:00 fw1.ztna.lab filterlog[28803] 1,121,,1790338518,vtnet3,match,block,in,4,0x0,,64,49290,0,DF,6,tcp,60,10.10.30.20,172.16.0.10,59452,22,0,S,...
```

## Senders

| Sender | Transport |
|---|---|
| RADIUS1, AppServer | TCP 514, RFC 5424, octet-counted framing, disk-assisted queue `fwd_ztna` capped at 100 MB, kept across restarts, unlimited retries |
| FW1 | UDP 514, RFC 5424, from the IT interface (10.10.30.1), "Everything" (pfSense supports UDP only) |
| LOG1 | Its own messages through the same storage ruleset |

Source enrichment:

- **Keycloak** logs successful logins as well as failures (`type="LOGIN"` with the
  username; `LOGIN_ERROR` carries only the userId).
- **FreeRADIUS** logs every result, never a password.
- **nginx** uses a dedicated format; `upstream=-` means a refusal by an nginx context rule,
  `upstream=403` a refusal by oauth2-proxy (wrong group). The request is logged without its
  query string, so OAuth codes never reach the logs.

## Investigation views (lnav, LOG1)

A custom format decodes the collector lines and FW1's CSV records into named fields
(interface, action, protocol, source, destination, port). Shortcuts in labadmin's
`.bashrc`:

| Alias | View |
|---|---|
| `ztnalog` | Today, without routine noise |
| `ztnaauth` | Authentication, access and blocking events plus detection alerts |
| `ztnahist` | All rotated files (14 days) |

## Detection (LOG1)

`/usr/local/bin/ztna-detect.sh` runs every 5 minutes from a systemd timer, under the
dedicated account `ztnadetect` (reads the logs, cannot modify them) inside a systemd
sandbox (`ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`, writable paths limited to
its state and alert directories). It reads only the bytes added since the last run, handles
rotation and defers an incomplete last line.

| Rule | Detects | Condition | Severity |
|---|---|---|---|
| R1 | Scan | One source blocked by FW1 on ≥10 distinct destination:port pairs | Medium |
| R2 | East-west probe | ≥3 ufw blocks from one source on one host | Medium |
| R3 | VPN password guessing | ≥3 RADIUS rejects for one user | High |
| R4 | Web password guessing | ≥3 Keycloak login errors for one user, any realm | High |
| R5 | Misplaced access | ≥3 denials for one client and app (wrong place or wrong group) | Medium |
| R6 | Clock skew | Event and reception time of a host's latest line differ by ≥60 s | Medium |
| R7 | Silent source | No line from an expected host for 15 minutes; informational alert on return | High |

Values copied from logs into alerts (including usernames typed by an attacker) are
restricted to a safe character set and length. Alerts go to `alerts.log` and to syslog.

`/usr/local/bin/ztna-digest.sh` runs hourly and writes a one-page daily summary (alerts,
logins, denials, blocks, host firewall blocks, volume per source), kept 30 days.

## Host hardening

**ufw** (default deny incoming, logging low):

| Server | Allowed incoming |
|---|---|
| AppServer | TCP 443 from any (FW1 decides who reaches it); TCP 22 from IT1 and `VPN_IT` |
| RADIUS1 | UDP 1812–1813 from FW1 (172.16.0.1) only; TCP 22 from IT1 and `VPN_IT` |
| LOG1 | UDP 514 from FW1; TCP 514 from AppServer and RADIUS1; TCP 22 from IT1 and `VPN_IT` |

Docker-published ports bypass ufw (destination NAT before INPUT); they are safe only because
they are bound to 127.0.0.1.

**SSH**, `/etc/ssh/sshd_config.d/00-ztna-hardening.conf` on the three servers (the `00-`
prefix wins over `50-cloud-init.conf`):

```text
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AuthenticationMethods publickey
```

## Tests

| Test | Expected | Evidence |
|---|---|---|
| Marker lines from every source; TCP sessions from .10 and .20 | Arrived | Reported |
| Queue outage test with both `syslog.socket` and `rsyslog.service` stopped | Queued line arrives later with its original time | **Not done** (first attempt invalid) |
| ufw rules and defaults on 3 servers | As above | **Verified** (screenshots) |
| ufw regression and denials (RADIUS1→AppServer 22/8080/4180, AppServer→RADIUS1 1812, IT1→LOG1 514) | Blocked and logged | Reported |
| Docker port mappings bound to 127.0.0.1 | Yes | Reported |
| Detection triggers R1–R6, digest | Alerts | Reported |
| R7 trigger (logging stopped 16 minutes) | source-silent then source-restored | **Not done** |

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| lnav jumped to September logs | Format not applied; files shown in name order | Shortcut on the current file; format checked with a headless count |
| nginx program recorded as "appserver" | nginx adds its host name to local syslog | `nohostname` |
| Keycloak errors without a username | `LOGIN_ERROR` carries only the userId | userId → username map learned from `LOGIN` events |
| FW1 20 h 38 min behind, nodes correct | VM paused by Windows Modern Standby; ntpd's 1000 s limit | Power settings (`powercfg` standby, monitor and hibernate timeouts 0 on mains), Service Watchdog, rule R6 |
| Outage test showed no queueing | `syslog.socket` restarted rsyslog | Stop both units |
| `grep: binary file matches` on `all.log` | NUL bytes after a hard stop | `grep -a`, rotation, clean shutdowns |
| Sender timestamps without year or zone | Legacy forward format | RFC 5424 template on senders |
| LOG1 locked out | Hardened before the key was installed | Recovered through the serial console |
| SSH passwords still accepted | `50-cloud-init.conf` re-enabled them | `00-ztna-hardening.conf` |
