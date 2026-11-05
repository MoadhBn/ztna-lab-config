# Extension Phase 3: Warpgate as the only administrative path

**Date:** 31 October to 1 November 2026. **Commit:** the commit that adds this file.
**State:** done; negative tests run on 1 November; FW1 break-glass test run on 3 November. Previous phase: [13-ext-phase-2b-web-targets.md](13-ext-phase-2b-web-targets.md).

## Goal

Until this phase Warpgate was one administrative path among others. It is now the only one
reachable over the network. Every direct path is closed, and every component keeps a
break-glass path that needs hypervisor (console) access.

## Vendor facts checked before the changes

| Source | Fact | Used for |
|---|---|---|
| Netgate, *Locked out of the WebGUI* | From the console shell, `easyrule pass wan tcp <client> <wan-ip> 443` adds a single pass rule; `pfctl -d` would disable the whole firewall | FW1 break-glass: the narrow rule, not `pfctl -d` |
| Warpgate, *User authentication* | For SSO users over SSH, the terminal prints a URL and a short security key; the user approves in the browser | Configuration exports through Warpgate with `scp`, without any personal key on the servers |

## What was closed and what replaces it

| Direct path before | Change | Replaced by |
|---|---|---|
| FW1 OpenVPN `VPN_IT → INTERNAL_NETS:22` | Deleted | Warpgate SSH targets |
| FW1 IT `IT_ADMIN → INTERNAL_NETS:22` | Deleted | Warpgate SSH targets |
| FW1 WAN `ADMIN_PC → FW1:443` | Disabled (kept for the record) | `fw1.pam.ztna.lab` |
| FW1 anti-lockout rule (GUI from the whole IT segment) | Disabled | `fw1.pam.ztna.lab` |
| OpenVPN route to LOG1 `10.10.30.20/32` | Removed (local networks now `172.16.0.0/24, 10.10.60.10/32`) | Not needed |
| ufw SSH from IT1 and `VPN_IT` on AppServer, RADIUS1, LOG1, PAM1 | Deleted | `22 from 10.10.60.10` only (PAM1: loopback) |
| PAM1 ufw `22 from 10.10.50.49` (temporary, exports) | Deleted | Exports through Warpgate |
| labadmin's SSH keys on the servers (IT1 key, `ztna-export`) | `authorized_keys` emptied (backup copy in `/root`) | labadmin is console-only (break-glass) |
| nginx: `VPN_IT` and IT1 on Keycloak `/admin`, `/realms/master` | Deleted | `kcadmin.pam.ztna.lab` (`allow 10.10.60.10` only) |
| PAM1 administered by direct SSH from IT1 | Rule deleted | Warpgate target `pam1` (`127.0.0.1:22`, approval) |

FW1 settings in this phase, all **Verified** in `nodes/fw1/config-redacted.xml`: the two SSH
rules gone, the WAN GUI rule disabled, `noantilockout` set, Login Protection pass list
`10.10.60.10/32`, OpenVPN local networks without LOG1.

## Approval rule (decision reversed)

In Extension Phase 2B only RADIUS1 required approval. Applying the same criterion (control of
identity) to AppServer, which runs Keycloak and holds the applications' secrets, gives the
same answer, so the rule is now:

| Target | Approval | Reason |
|---|---|---|
| `radius1` | Yes | VPN and pfSense logins |
| `appserver` | Yes | Keycloak and the application secrets |
| `pam1` | Yes | The gateway itself: roles, approvals, recordings |
| `log1` | No | Routine investigation; tampering is covered by signed manifests (Phase 5) and the Wazuh copy (Phase 7) |
| `fw1-gui`, `keycloak-admin` | No | Warpgate refuses HTTP requests while approval is pending; each console has its own second login |

## Break-glass paths

| Component | Normal path | Break-glass (needs console access) |
|---|---|---|
| Servers | Warpgate → `pamops` | EVE serial console, `labadmin` with password |
| FW1 GUI | `fw1.pam.ztna.lab`, RADIUS login | FW1 console → option 8 → `easyrule pass wan tcp 192.168.78.1 192.168.78.20 443`; delete the rule afterwards |
| Warpgate | Keycloak SSO | Local `admin`; PAM1 console and `warpgate recover-access` |
| Keycloak admin | `kcadmin.pam.ztna.lab` | AppServer console and `bootstrap-admin` ([13-ext-phase-2b-web-targets.md](13-ext-phase-2b-web-targets.md)) |

## PAM1 as its own target

| Item | Value |
|---|---|
| Account `pamops` on PAM1 | Password locked; `authorized_keys` = Warpgate's key with `from="127.0.0.1"` (fingerprint `ZyENO54S…`); `/etc/sudoers.d/90-pamops` |
| Warpgate target `pam1` | SSH `127.0.0.1:22`, user `pamops`, ed25519 key, role `ops`, approval required |

Known limitation: root on PAM1 can alter Warpgate's recordings. Approval limits who gets
there; Extension Phases 6 and 7 send Warpgate's logs off the machine and watch the
recordings for changes.

## Exports through Warpgate

```text
(Warpgate web session to the target)   sudo rm -f /tmp/ztna-config-*.tgz ; sudo ztna-config-export
(Windows, VPN as itadmin)              scp -P 2222 -o User=itadmin:<target> "pam.ztna.lab:/tmp/ztna-config-*.tgz" <repo>\incoming\
(Warpgate web session to the target)   sudo rm -f /tmp/ztna-config-*.tgz
```

The archive belongs to `pamops` (the script gives it to the `sudo` caller), so the brokered
account can read it. `-o User=` is needed because `scp` would read the `:` in
`itadmin:appserver` as a path separator. On the approval targets, `secops` also approves the
`scp` session.

## Tests

| # | Test | Expected | Evidence |
|---|---|---|---|
| 1 | ufw on the four servers after the change | `22` from `10.10.60.10` only (PAM1: none) | **Verified** (`ufw status numbered` in Warpgate sessions as `pamops` on `appserver`, `radius1`, `log1`, `pam1`; also in the exported `user.rules`) |
| 2 | Warpgate session to `pam1` | Works | **Verified** (session prompt `pamops@pam1`) |
| 3 | `scp` through Warpgate with in-browser approval | File copied | **Verified**: URL and security key shown; pressing Enter before approving gives "Browser authentication was not confirmed, please try again"; after approving, the archive copies |
| 4 | Keycloak admin console without the `X-Forwarded-Host` map | Works | Reported (the map was removed, `ztna-common.conf` uses `$host` again) |
| 5 | nginx admin rule | `allow 10.10.60.10` only | **Verified** in the export |
| 6 | Host key of `pam1` = inventory value `kNRjQ…` | Matches | Not recorded |
| 7 | labadmin `authorized_keys` empty on the four servers | `0` bytes | Not recorded |
| N1 | `ssh -l labadmin` from IT1 to AppServer, RADIUS1, LOG1, PAM1, VAULT1 | No connection | **Verified** (1 November: no connection to any; attempts interrupted, no prompt) |
| N2 | `ssh labadmin@172.16.0.20` from Windows over the itadmin VPN | Timeout | **Verified** (`Connection timed out`) |
| N3 | `https://192.168.78.20` from Windows | Unreachable | **Verified** (`ERR_CONNECTION_TIMED_OUT`) |
| N4 | `curl https://10.10.30.1` from IT1 | Unreachable | **Verified** (no answer; interrupted) |
| N5 | `https://auth.ztna.lab/admin/` over the itadmin VPN | `403` | **Verified** |
| N6 | `Test-NetConnection 10.10.30.20 -Port 22` over the reconnected itadmin VPN | Fails | **Verified** (`TcpTestSucceeded False`) |
| BG | FW1 break-glass with `easyrule` | GUI reachable, then closed again | **Verified** (3 November): WAN rule "Passed via EasyRule" `192.168.78.1 → 192.168.78.20:443` with 1 state / 1.81 MiB (the GUI was reached through it); after deletion the WAN tab shows only the bogon block, the disabled ADMIN_PC GUI rule and the OpenVPN rule; `https://192.168.78.20` from Windows → `ERR_CONNECTION_TIMED_OUT` |

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| Warpgate refused `itadmin`: "No user matching sofien@ztna.lab" | The browser still held sofien's Keycloak session from the HR test; changing the VPN account does not change the browser's identity, and SSO reused it | Keycloak logout, then login as itadmin. Not a fault: Warpgate checks the person's Keycloak identity, whatever VPN the traffic arrives on |
| `scp` kept asking "Press Enter when done" | Enter was pressed before the browser approval | Approve in the `itadmin` browser first, then press Enter |
| The `X-Forwarded-Host` map of 2B part 2 | Needed only while `KC_HOSTNAME_ADMIN` was set | Removed and retested |

## Still open

- ~~Run the FW1 break-glass test~~ (done 3 November). Before that, a broken
  Warpgate path to `fw1-gui` would have to be recovered with a procedure never tried.
- Record tests 6 and 7.
- Make a new encrypted FW1 backup: the last one (31 October 19:50) may predate the Step 4
  changes.
- Delete the Windows key files `ztna-export` and `ztna-export.pub`; no server trusts them any more.
- Give a description to the remaining unnamed FW1 rules and delete REMOTE's disabled unnamed
  block rule (not done in this phase).
- The comment above nginx's admin rule still says "VPN_IT range + jump host IT1".
