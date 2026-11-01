# ZTNA lab: project status

Updated at the end of every phase. This file, the repository and the two LaTeX documents
(`report.tex`, `technical_documentation.tex`) are the record of the project; it does not
depend on any chat transcript.

Last update: 2026-11-01 (Extension Phases 3 and 4A-4B done; FW1 break-glass test and a fresh encrypted FW1 backup still owed). Phase-by-phase records of the whole project: [docs/](docs/README.md). The roadmap below uses the extension phase numbers.

## What exists

| Layer | Components | State |
|---|---|---|
| Network | pfSense FW1, segments HR / FIN / IT / REMOTE / DMZ, default deny, ufw on servers | Built |
| Identity | FreeRADIUS on RADIUS1, TOTP, per-user passwords (SHA-512-crypt, 100,000 rounds), BlastRADIUS settings on client fw1 | Built |
| Remote access | OpenVPN on FW1: certificate + password + TOTP, strict CN, CRL `ZTNA-Lab-CRL`, one /28 per group | Built |
| Applications | nginx, oauth2-proxy (hr, fin), Keycloak 26.3 + PostgreSQL on AppServer, images pinned by digest | Built |
| Visibility | LOG1: rsyslog collector, lnav views, detection R1-R7, daily digest | Built |
| Secrets | Vault 2.2.1 on VAULT1: OIDC login for `it-admins` (policy `vault-admin`, audit settings denied), UI at `vault.pam.ztna.lab` through Warpgate, no standing root token | Server and admin access done; secrets in 4C-4D |
| Baseline | This repository (sanitised configs), encrypted pfSense backups in `C:\ztna-backups\` outside Git | Done (Phase 0) |
| Privileged access | Warpgate v0.30.0 on PAM1: Keycloak SSO (`it-admins` → role `ops`), SSH targets AppServer, RADIUS1, LOG1 as `pamops`; target `pam1` (the gateway itself); per-session approval for RADIUS1, AppServer and PAM1 by a separate approver (`pam-approvers` → admin role `approver`); command log and session recording; web targets pfSense GUI (`fw1.pam.ztna.lab`, RADIUS login) and Keycloak admin console (`kcadmin.pam.ztna.lab`, `kcadmin` + OTP) | Done; the only administrative path since Phase 3 |

## Roadmap

| Phase | Content | State |
|---|---|---|
| 0 | Baseline: repository, backups, host identity check | Done, commit `3197fca` |
| 1 | SEC segment 10.10.60.0/24 (FW1 `vtnet6`, EVE Cloud2, VMware VMnet3), PAM1 base host | Done, commit `53619eb` (PAM1 test outputs not recorded) |
| 2A | Warpgate on PAM1 (10.10.60.10): Keycloak SSO, role `ops`, first SSH target AppServer, recording | Done, commit `b31d53b` ([docs/11](docs/11-ext-phase-2a-warpgate.md)) |
| 2B part 1 | Targets RADIUS1 and LOG1, separate approver and per-session approval for RADIUS1, ticket evaluation, negative tests | Done, commit `137e74e` ([docs/12](docs/12-ext-phase-2b-targets-approvals.md)) |
| 2B part 2 | Web targets: pfSense GUI (RADIUS login), Keycloak admin console | Done, commit `8584ed5` ([docs/13](docs/13-ext-phase-2b-web-targets.md)) |
| 3 | Enforce PAM: remove direct SSH and GUI paths, Warpgate only | Done, commit `a21ecf4` ([docs/14](docs/14-ext-phase-3-enforce-pam.md)); negative tests passed, FW1 break-glass test to run |
| 4A-4B | Vault 2.2.1 on VAULT1 (10.10.60.20): TLS, raft, Shamir 5/3, audit log; admin login through Keycloak (`it-admins`), UI through Warpgate, root token revoked | Done ([docs/15](docs/15-ext-phase-4ab-vault.md)) |
| 4C-4D | Vault: application secrets with Vault Agent; SSH certificates for Warpgate's targets and the backup job; break-glass secrets; Transit | Not started |
| 5 | Encrypted backups, signed log manifests, restore drill | Not started |
| 6 | Audit integration: Warpgate, Vault, sudo, auditd into LOG1; LOG1 feed to Wazuh | Not started |
| 7 | Wazuh VM (10.10.60.30): agents, decoders, rules; `ztna-detect` reduced to R6/R7 + R8 | Not started |
| 8 | AI triage, advisory only | Not started |
| 9 | Validation: full scenario catalogue, recorded evidence | Not started |

## Decisions

- Security services live in their own SEC segment, so every flow to them crosses FW1.
- Secrets manager: HashiCorp Vault Community.
- Wazuh dashboard login through Keycloak SSO; the local Wazuh admin is break-glass only.
- All infrastructure administration goes through Warpgate (enforced since Phase 3). Break-glass
  paths need console access: EVE serial consoles (labadmin), FW1 console `easyrule`, Warpgate
  local `admin`, Keycloak `bootstrap-admin`.
- No new login system: people authenticate only through Keycloak or RADIUS. Warpgate access
  tickets bypass Keycloak, so they are not used for people.
- Sessions on RADIUS1, AppServer and PAM1 need the approval of a second person (group
  `pam-approvers`); LOG1 and the web targets do not. The local Warpgate `admin` is
  break-glass only.
- AI provider: decided at Phase 8.
- Attack scenarios run once, at the end, on the final configuration.

## Temporary exceptions

None since Phase 3. Exports go through Warpgate; labadmin has no SSH key on any server. The
OpenVPN route to PAM1 (`10.10.60.10/32`) is permanent for `VPN_IT` administrators; FW1 blocks
the other groups.

## Checks still to run

- FW1 break-glass test with `easyrule` ([docs/14](docs/14-ext-phase-3-enforce-pam.md)).
- New encrypted FW1 backup: the newest in `C:\ztna-backups\` (31 October 19:50) predates the
  Phase 3, 4A and 4B FW1 changes.
- Record: the `pam1` and `vault1` host keys pinned in Warpgate; the empty labadmin
  `authorized_keys` on the five servers.

## Known differences between the real configuration and the documents

Fixed in Phase 1 (checked in the re-exported `nodes/fw1/config-redacted.xml`):

- The last rule of the OpenVPN tab was Reject; it is now Block.
- The OpenVPN fallback cipher was `AES-256-CBC`; it is now `AES-256-GCM`.
- The duplicate GUI rule on the WAN tab is removed.
- The final rules of IT, HR, FIN, REMOTE and DMZ are named `Default deny <TAB>`.

Still open:

- Every SEC rule is now named. Rules without a description remain on the OpenVPN tab (5 of 7)
  and on IT, HR, FIN, REMOTE and DMZ; REMOTE also keeps a disabled, unnamed block rule in the
  middle of the list.
- The comment above nginx's admin rule still names VPN_IT and IT1, which are no longer allowed.
- FW1 SEC rule description typo: `VAULT1 to Keycloadk (OIDC)`.
- `vault login` prints the token; use `vault login -no-print` in recorded Warpgate sessions.
- Five exported `.ovpn` profiles, each embedding a user's private key, are in the Windows
  `Downloads` folder; delete them once imported into the OpenVPN client.
- `ztna-config-export` fails when an archive with the same name owned by labadmin is left in
  `/tmp`; the script removes it first from Phase 5.
- The WAN tab has no explicit logged block rule (pfSense's implicit default deny applies).
- `report.tex` and `technical_documentation.tex` do not cover the extension (Phases 1-9)
  and still state that a SIEM is out of scope and that the lab fits in 8 GB.

## Evidence still owed (captured in Phase 9)

Output was never recorded for: image pinning, Keycloak password policy, the RADIUS password
change, the CRL refusal line (`VERIFY ERROR ... certificate revoked`), time sync on every
node, detection triggers R1-R7, the syslog queue outage test, Keycloak lockout and
mid-session revocation, the Phase 4 VPN tests, the Extension Phase 1 PAM1 tests, and all
attack scenarios.
