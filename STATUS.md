# ZTNA lab: project status

Updated at the end of every phase. This file, the repository and the two LaTeX documents
(`report.tex`, `technical_documentation.tex`) are the record of the project; it does not
depend on any chat transcript.

Last update: 2026-10-30 (Extension Phase 2A complete; Phase 2B not started). Phase-by-phase records of the whole project: [docs/](docs/README.md). The roadmap below uses the extension phase numbers.

## What exists

| Layer | Components | State |
|---|---|---|
| Network | pfSense FW1, segments HR / FIN / IT / REMOTE / DMZ, default deny, ufw on servers | Built |
| Identity | FreeRADIUS on RADIUS1, TOTP, per-user passwords (SHA-512-crypt, 100,000 rounds), BlastRADIUS settings on client fw1 | Built |
| Remote access | OpenVPN on FW1: certificate + password + TOTP, strict CN, CRL `ZTNA-Lab-CRL`, one /28 per group | Built |
| Applications | nginx, oauth2-proxy (hr, fin), Keycloak 26.3 + PostgreSQL on AppServer, images pinned by digest | Built |
| Visibility | LOG1: rsyslog collector, lnav views, detection R1-R7, daily digest | Built |
| Baseline | This repository (sanitised configs), encrypted pfSense backups in `C:\ztna-backups\` outside Git | Done (Phase 0) |
| Privileged access | Warpgate v0.30.0 on PAM1: Keycloak SSO (`it-admins` → role `ops`), SSH target AppServer as `pamops`, command log and session recording | 2A done; other targets in 2B |

## Roadmap

| Phase | Content | State |
|---|---|---|
| 0 | Baseline: repository, backups, host identity check | Done, commit `3197fca` |
| 1 | SEC segment 10.10.60.0/24 (FW1 `vtnet6`, EVE Cloud2, VMware VMnet3), PAM1 base host | Done, commit `53619eb` (PAM1 test outputs not recorded) |
| 2A | Warpgate on PAM1 (10.10.60.10): Keycloak SSO, role `ops`, first SSH target AppServer, recording | Done ([docs/11](docs/11-ext-phase-2a-warpgate.md)); some evidence owed |
| 2B | Targets RADIUS1 and LOG1, per-session approval for RADIUS1, access tickets, web targets (pfSense GUI, Keycloak `/admin`), negative tests | Not started |
| 3 | Enforce PAM: remove direct SSH and GUI paths, Warpgate only | Not started |
| 4 | Vault on VAULT1 (10.10.60.20): KV secrets, SSH CA (Warpgate targets and the backup job), break-glass, Transit | Not started |
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

- Windows export key, restricted to `from="10.10.50.49"`, in labadmin's `authorized_keys`:
  `ztna-export` on AppServer and PAM1 (replaced `phase0-export`, whose passphrase was lost,
  on 30 October). The old `phase0-export` line is still on RADIUS1 and LOG1; remove it there.
- PAM1 ufw: SSH from `10.10.50.49` (exports) and from IT1 (build phase).
- OpenVPN pushes routes to `10.10.30.20/32` (LOG1) and `10.10.60.10/32` (PAM1) to every VPN
  client. The PAM1 route is permanent for `VPN_IT` administrators; FW1 still blocks other
  groups.
- Direct SSH from IT1 and `VPN_IT` to the servers (`IT_ADMIN → INTERNAL_NETS:22`,
  `VPN_IT → INTERNAL_NETS:22`).

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
- PAM1 keeps the installer's netplan file (`dhcp6: true` merged into the static configuration); remove it in 2B.
- The WAN tab has no explicit logged block rule (pfSense's implicit default deny applies).
- `report.tex` and `technical_documentation.tex` do not cover the extension (Phases 1-9)
  and still state that a SIEM is out of scope and that the lab fits in 8 GB.

## Evidence still owed (captured in Phase 9)

Output was never recorded for: image pinning, Keycloak password policy, the RADIUS password
change, the CRL refusal line (`VERIFY ERROR ... certificate revoked`), time sync on every
node, detection triggers R1-R7, the syslog queue outage test, Keycloak lockout and
mid-session revocation, the Phase 4 VPN tests, the Extension Phase 1 PAM1 tests, and all
attack scenarios.

Extension Phase 2A, still to capture: FW1 block line for sofien → PAM1 on LOG1, Warpgate's
refusal of sofien, the Windows certificate dialog for `pam.ztna.lab`, replay playback;
confirmation that the exposed Keycloak client secret was regenerated and that PKCE is `S256`.
