# ZTNA lab: project status

Updated at the end of every phase. This file, the repository and the two LaTeX documents
(`report.tex`, `technical_documentation.tex`) are the record of the project; it does not
depend on any chat transcript.

Last update: 2026-10-08 (Phase 0 complete, Phase 1 in progress).

## What exists

| Layer | Components | State |
|---|---|---|
| Network | pfSense FW1, segments HR / FIN / IT / REMOTE / DMZ, default deny, ufw on servers | Built |
| Identity | FreeRADIUS on RADIUS1, TOTP, per-user passwords (SHA-512-crypt, 100,000 rounds), BlastRADIUS settings on client fw1 | Built |
| Remote access | OpenVPN on FW1: certificate + password + TOTP, strict CN, CRL `ZTNA-Lab-CRL`, one /28 per group | Built |
| Applications | nginx, oauth2-proxy (hr, fin), Keycloak 26.3 + PostgreSQL on AppServer, images pinned by digest | Built |
| Visibility | LOG1: rsyslog collector, lnav views, detection R1-R7, daily digest | Built |
| Baseline | This repository (sanitised configs), encrypted pfSense backup outside Git | Done (Phase 0) |

## Roadmap

| Phase | Content | State |
|---|---|---|
| 0 | Baseline: repository, backups, host identity check | Done, commit `3197fca` |
| 1 | SEC segment 10.10.60.0/24 (FW1 `vtnet6`, EVE Cloud2, VMware VMnet3), PAM1 base host | FW1 side verified from the exported config; PAM1 tests reported done, outputs not recorded |
| 2 | Warpgate on PAM1 (10.10.60.10): Keycloak SSO, role `ops`, SSH and web targets, recording | Not started |
| 3 | Enforce PAM: remove direct SSH and GUI paths, Warpgate only | Not started |
| 4 | Vault on VAULT1 (10.10.60.20): KV secrets, SSH CA for the backup job, break-glass, Transit | Not started |
| 5 | Encrypted backups, signed log manifests, restore drill | Not started |
| 6 | Audit integration: Warpgate, Vault, sudo, auditd into LOG1; LOG1 feed to Wazuh | Not started |
| 7 | Wazuh VM (10.10.60.30): agents, decoders, rules; `ztna-detect` reduced to R6/R7 + R8 | Not started |
| 8 | AI triage, advisory only | Not started |
| 9 | Validation: full scenario catalogue, recorded evidence | Not started |

## Decisions

- Security services live in their own SEC segment, so every flow to them crosses FW1.
- Secrets manager: HashiCorp Vault Community.
- Wazuh dashboard login through Keycloak SSO; the local Wazuh admin is break-glass only.
- All infrastructure administration goes through Warpgate once Phase 3 is done.
- No new login system: people authenticate only through Keycloak or RADIUS.
- AI provider: decided at Phase 8.
- Attack scenarios run once, at the end, on the final configuration.

## Temporary exceptions (to close in Phase 3)

- Windows key `phase0-export`, restricted to `from="10.10.50.49"`, in labadmin's
  `authorized_keys` on AppServer, RADIUS1 and LOG1.
- OpenVPN pushes a route to `10.10.30.20/32` (LOG1) to every VPN client.

## Known differences between the real configuration and the documents

Fixed in Phase 1 (checked in the re-exported `nodes/fw1/config-redacted.xml`):

- The last rule of the OpenVPN tab was Reject; it is now Block.
- The OpenVPN fallback cipher was `AES-256-CBC`; it is now `AES-256-GCM`.
- The duplicate GUI rule on the WAN tab is removed.
- The final rules of IT, HR, FIN, REMOTE and DMZ are named `Default deny <TAB>`.

Still open:

- The four SEC rules and the OpenVPN rules have no description.
- The WAN tab has no explicit logged block rule (pfSense's implicit default deny applies).
- `report.tex` and `technical_documentation.tex` do not cover the extension (Phases 1-9)
  and still state that a SIEM is out of scope and that the lab fits in 8 GB.

## Evidence still owed (captured in Phase 9)

Output was never recorded for: image pinning, Keycloak password policy, the RADIUS password
change, the CRL refusal line (`VERIFY ERROR ... certificate revoked`), time sync on every
node, detection triggers R1-R7, the syslog queue outage test, and all attack scenarios.
