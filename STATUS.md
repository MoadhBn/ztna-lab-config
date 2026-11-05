# ZTNA lab: project status

Updated at the end of every phase. This file, the repository and the two LaTeX documents
(`report.tex`, `technical_documentation.tex`) are the record of the project; it does not
depend on any chat transcript.

Last update: 2026-11-05 (Extension Phase 5 done: encrypted backups, signed manifests, RADIUS1 restore drill; FW1 break-glass test and root-generation ceremony recorded). Phase-by-phase records of the whole project: [docs/](docs/README.md). The roadmap below uses the extension phase numbers.

## What exists

| Layer | Components | State |
|---|---|---|
| Network | pfSense FW1, segments HR / FIN / IT / REMOTE / DMZ, default deny, ufw on servers | Built |
| Identity | FreeRADIUS on RADIUS1, TOTP, per-user passwords (SHA-512-crypt, 100,000 rounds), BlastRADIUS settings on client fw1 | Built |
| Remote access | OpenVPN on FW1: certificate + password + TOTP, strict CN, CRL `ZTNA-Lab-CRL`, one /28 per group | Built |
| Applications | nginx, oauth2-proxy (hr, fin), Keycloak 26.3 + PostgreSQL on AppServer, images pinned by digest | Built |
| Visibility | LOG1: rsyslog collector, lnav views, detection R1-R7, daily digest | Built |
| Secrets | Vault 2.2.1 on VAULT1: OIDC login for `it-admins` (policy `vault-admin`, audit settings denied), UI at `vault.pam.ztna.lab` through Warpgate, no standing root token | Done: admin access, application secrets, SSH CA for Warpgate, Transit, break-glass entries |
| Baseline | This repository (sanitised configs), encrypted pfSense backups in `C:\ztna-backups\` outside Git | Done (Phase 0) |
| Backups | Nightly job on LOG1 (`ztna-backup.timer`, 02:30): 5-minute Vault certificate per server for the account `ztnabackup` (forced command, from LOG1 only, enforced by the servers' principals files), archives encrypted on each server with the public half of Transit key `backup-kek`, Vault raft snapshot through the API, signed and chained manifests (key `manifest-sign`), 14 days on LOG1 plus a copy in `C:\ztna-backups\lab\`; decryption only with the OIDC role `backup-restore` | Done; RADIUS1 rebuilt from a backup in about 27 minutes |
| Privileged access | Warpgate v0.30.0 on PAM1: Keycloak SSO (`it-admins` → role `ops`), SSH targets AppServer, RADIUS1, LOG1, VAULT1 as `pamops`, authenticated with 5-minute certificates signed by Vault (no standing key); target `pam1` (the gateway itself); per-session approval for RADIUS1, AppServer and PAM1 by a separate approver (`pam-approvers` → admin role `approver`); command log and session recording; web targets pfSense GUI (`fw1.pam.ztna.lab`, RADIUS login) and Keycloak admin console (`kcadmin.pam.ztna.lab`, `kcadmin` + OTP) | Done; the only administrative path since Phase 3 |

## Roadmap

| Phase | Content | State |
|---|---|---|
| 0 | Baseline: repository, backups, host identity check | Done, commit `3197fca` |
| 1 | SEC segment 10.10.60.0/24 (FW1 `vtnet6`, EVE Cloud2, VMware VMnet3), PAM1 base host | Done, commit `53619eb` (PAM1 test outputs not recorded) |
| 2A | Warpgate on PAM1 (10.10.60.10): Keycloak SSO, role `ops`, first SSH target AppServer, recording | Done, commit `b31d53b` ([docs/11](docs/11-ext-phase-2a-warpgate.md)) |
| 2B part 1 | Targets RADIUS1 and LOG1, separate approver and per-session approval for RADIUS1, ticket evaluation, negative tests | Done, commit `137e74e` ([docs/12](docs/12-ext-phase-2b-targets-approvals.md)) |
| 2B part 2 | Web targets: pfSense GUI (RADIUS login), Keycloak admin console | Done, commit `8584ed5` ([docs/13](docs/13-ext-phase-2b-web-targets.md)) |
| 3 | Enforce PAM: remove direct SSH and GUI paths, Warpgate only | Done, commit `a21ecf4` ([docs/14](docs/14-ext-phase-3-enforce-pam.md)); negative tests and FW1 break-glass test passed |
| 4A-4B | Vault 2.2.1 on VAULT1 (10.10.60.20): TLS, raft, Shamir 5/3, audit log; admin login through Keycloak (`it-admins`), UI through Warpgate, root token revoked | Done, commit `3c4b2fc` ([docs/15](docs/15-ext-phase-4ab-vault.md)) |
| 4C | AppServer's compose secrets in Vault (KV v2), Vault Agent with AppRole bound to AppServer, secrets in RAM only, rotation demo | Done, commit `8f54784` ([docs/16](docs/16-ext-phase-4c-app-secrets.md)) |
| 4D | Vault-signed 5-minute SSH certificates for all Warpgate targets (static key removed), Transit key `backup`, write-only break-glass secrets, root generation without login | Done, commit `1fc7d39` ([docs/17](docs/17-ext-phase-4d-ssh-ca-transit-breakglass.md)) |
| 5 | Encrypted backups, signed log manifests, restore drill | Done ([docs/18](docs/18-ext-phase-5-backups.md)) |
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
- Backups (Phase 5): the job runs on LOG1 and receives only ciphertext; the servers encrypt with
  a public key, so neither LOG1 nor an ordinary Vault administrator can read a backup. The
  machine path LOG1 → port 22 of AppServer, RADIUS1, PAM1, VAULT1 is not an administrative path:
  one forced command, no shell, no forwarding.

## Temporary exceptions

None since Phase 3. Exports go through Warpgate; labadmin has no SSH key on any server. The
OpenVPN route to PAM1 (`10.10.60.10/32`) is permanent for `VPN_IT` administrators; FW1 blocks
the other groups. The old RADIUS1 node (replaced in the Phase 5 drill) stays stopped until
Phase 5 is committed, then is deleted; it must never run together with the rebuilt one.

## Checks still to run

- Record the empty labadmin `authorized_keys` on the five servers. (The `pam1` and `vault1`
  host keys are now confirmed by LOG1's pins in Phase 5; Warpgate's own pins are not shown.)
- Restores not yet exercised: Keycloak database import, Warpgate database, Vault snapshot.
- Golden image: add the serial-console GRUB line (Phase 5 drill finding D1).
- VAULT1 reports pending updates (`System restart required`): plan the reboot with the unseal
  ceremony.
- Vault audit log: 3,199 NUL bytes at line 1273, between entries of 13:05:47 and 16:59:38 UTC on
  3 November, i.e. across an unclean stop of VAULT1 (the lab was stopped that day; zero-filled
  blocks are what a file system leaves after a power cut). The audit entries written in the
  lost window are gone. Phase 6 must tolerate such a line; stop the lab cleanly (`poweroff`
  on the consoles) or suspend the EVE-NG VM.

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
- Vault starts sealed after every cold start; Warpgate SSH targets and the backup job then fail until VAULT1 is unsealed on its console.
- The Vault 2.2.1 UI cannot verify a Transit signature (its Verify form only takes an HMAC); manifests are verified with OpenSSL and `nodes/vault1/vault-config/manifest-sign.pub.pem`.
- `vault-admin` can rewrite policies, its own included, so its `deny` lines are guard rails (Phase 5 finding F4); every policy write is audited and becomes a Wazuh rule in Phase 7.
- RADIUS1 logged one message with no host or program name (`/var/log/ztna/172.16.0.20/_.log`, 3 November); examine in Phase 6.
- `vault login` prints the token; use `vault login -no-print` in recorded Warpgate sessions.
- Five exported `.ovpn` profiles, each embedding a user's private key, are in the Windows
  `Downloads` folder; delete them once imported into the OpenVPN client.
- The WAN tab has no explicit logged block rule (pfSense's implicit default deny applies).
- `report.tex` and `technical_documentation.tex` do not cover the extension (Phases 1-9)
  and still state that a SIEM is out of scope and that the lab fits in 8 GB.

## Evidence still owed (captured in Phase 9)

Output was never recorded for: image pinning, Keycloak password policy, the RADIUS password
change, the CRL refusal line (`VERIFY ERROR ... certificate revoked`), time sync on every
node, detection triggers R1-R7, the syslog queue outage test, Keycloak lockout and
mid-session revocation, the Phase 4 VPN tests, the Extension Phase 1 PAM1 tests, and all
attack scenarios.
