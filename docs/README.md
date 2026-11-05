# ZTNA lab: project documentation

A simulated small enterprise (HR, Finance, IT, a server DMZ and remote employees) built in
EVE-NG, in which Zero Trust controls were added layer by layer following NIST SP 800-207,
then extended with privileged access management, secrets management, a SIEM and
AI-assisted triage.

This folder records the project phase by phase. Each file says what was built, why, how,
what went wrong and how it was fixed, and what evidence exists.

The project has two numbering schemes: the six **build phases** of the original Zero Trust
lab, and the **extension phases** 0 to 9 (privileged access, secrets, SIEM, AI triage).

### Original Zero Trust build

| File | Content | State |
|---|---|---|
| [01-foundations.md](01-foundations.md) | Platform, nodes, FW1 interfaces, golden image, serial consoles | Done |
| [02-segmentation.md](02-segmentation.md) | Flow matrix, aliases, default-deny rules per interface | Done |
| [03-central-identity.md](03-central-identity.md) | FreeRADIUS, users and groups, pfSense integration | Done |
| [04-remote-access.md](04-remote-access.md) | PKI, TOTP, OpenVPN, group ranges | Done |
| [05-application-access.md](05-application-access.md) | Keycloak, oauth2-proxy, nginx context rules | Done |
| [06-visibility-and-host-hardening.md](06-visibility-and-host-hardening.md) | Time, LOG1 collector, lnav, detection R1–R7, digest, ufw, SSH hardening | Built; some tests still owed |
| [07-hardening-sessions.md](07-hardening-sessions.md) | 7 October: image pinning, password policy, unique RADIUS passwords, BlastRADIUS, CRL, time on every node | Done |

### Extension

| File | Content | State |
|---|---|---|
| [08-extension-design.md](08-extension-design.md) | The brief, its corrections, the owner's decisions, the roadmap | Done |
| [09-ext-phase-0-baseline.md](09-ext-phase-0-baseline.md) | Configuration repository, sanitised exports, host identity check | Done |
| [10-ext-phase-1-sec-segment.md](10-ext-phase-1-sec-segment.md) | SEC segment for the security services, firewall cleanups, PAM1 base host | Done |
| [11-ext-phase-2a-warpgate.md](11-ext-phase-2a-warpgate.md) | Warpgate on PAM1, Keycloak SSO, first brokered SSH target, recording | Done |
| [12-ext-phase-2b-targets-approvals.md](12-ext-phase-2b-targets-approvals.md) | RADIUS1 and LOG1 as targets, separate approver, per-session approval, access tickets evaluated | Done (part 1) |
| [13-ext-phase-2b-web-targets.md](13-ext-phase-2b-web-targets.md) | pfSense GUI and Keycloak admin console through Warpgate, Keycloak admin lockout recovery | Done |
| [14-ext-phase-3-enforce-pam.md](14-ext-phase-3-enforce-pam.md) | Direct paths closed, break-glass paths, exports through Warpgate, approval rule extended | Done |
| [15-ext-phase-4ab-vault.md](15-ext-phase-4ab-vault.md) | Vault on VAULT1, initialisation ceremony, audit log, administrator login through Keycloak, root token revoked | Done |
| [16-ext-phase-4c-app-secrets.md](16-ext-phase-4c-app-secrets.md) | AppServer's secrets in Vault, Vault Agent and AppRole, rotation demo | Done |
| [17-ext-phase-4d-ssh-ca-transit-breakglass.md](17-ext-phase-4d-ssh-ca-transit-breakglass.md) | Vault-signed SSH certificates for Warpgate, Transit, break-glass secrets, root generation in Vault 2.x | Done |
| [18-ext-phase-5-backups.md](18-ext-phase-5-backups.md) | Encrypted backups pulled by LOG1 with Vault-signed certificates, signed log manifests, RADIUS1 restore drill | Done |
| Extension Phases 6 to 9 | Audit, Wazuh, AI triage, validation | Not started |

The current overall state and the open items are in [../STATUS.md](../STATUS.md). Every
address, endpoint, download and documentation link used in the project is in
[links.md](links.md).

## Evidence levels

Every result in these files carries one of these labels:

| Label | Meaning |
|---|---|
| **Verified** | The output was shown, or the result was checked in this repository (for example in the exported firewall configuration) |
| **Reported** | The operator ran the step and reported it working, but no output was recorded. Output is captured in the final validation phase. |
| **Not done** | Not implemented yet |

## Repository layout

| Path | Content |
|---|---|
| `nodes/<host>/` | Sanitised configuration of each node, exported by `scripts/ztna-config-export`; `PERMISSIONS.txt` and `SYMLINKS.txt` keep what Windows cannot store |
| `nodes/fw1/config-redacted.xml` | pfSense configuration with every secret element replaced by `REDACTED` (not restorable; the encrypted full backup is kept outside Git) |
| `inventory/` | Public identity data, such as SSH host key fingerprints |
| `scripts/` | Scripts installed on the nodes |
| `docs/` | This documentation |
| `STATUS.md` | Current state, roadmap, temporary exceptions, evidence still owed |

No secret is ever committed. Private keys, `.env` files and backup copies are dropped by the
export; password hashes, TOTP seeds and shared secrets are replaced by `<REDACTED>`.

## Addressing at a glance

| Segment | FW1 interface | Network | Hosts |
|---|---|---|---|
| WAN | `vtnet0` | 192.168.78.0/24 | FW1 .20, Windows admin PC .1, EVE-NG .10 (time server) |
| IT (pfSense LAN) | `vtnet3` | 10.10.30.0/24 | IT1 .10, LOG1 .20 |
| HR | `vtnet1` | 10.10.10.0/24 | HR1, HR2 (DHCP), Windows HR office PC .50 |
| FIN | `vtnet2` | 10.10.20.0/24 | FIN1, FIN2 (DHCP) |
| REMOTE | `vtnet4` | 10.10.40.0/24 | REMOTE1 |
| DMZ | `vtnet5` | 172.16.0.0/24 | AppServer .10, RADIUS1 .20 |
| SEC (Ext. Phase 1) | `vtnet6` | 10.10.60.0/24 | PAM1 .10 (Warpgate), VAULT1 .20 (Vault), Wazuh .30 (planned) |
| OpenVPN | `ovpns1` | 10.10.50.0/24 | One /28 per group: HR .16, FIN .32, IT .48 |
