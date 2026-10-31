# Extension design (8 October 2026)

The lab was extended with an implementation brief: privileged access management, secrets
management, a SIEM and AI-assisted triage, with clear responsibilities and **no new
authentication system** (people authenticate only through Keycloak or RADIUS).

The extension has its own phase numbers, **Extension Phase 0 to 9**, distinct from the six
original build phases.

## Corrections made to the brief

| Brief | Correction | Reason |
|---|---|---|
| Vault sits between Warpgate and the servers | Vault sits **beside** the access path | Warpgate has no Vault integration and injects its own key; humans need no server credential |
| Vault issues SSH credentials to administrators | Vault issues short-lived SSH certificates to the **backup job** only | Credentials for humans would create a second administrative path that bypasses Warpgate |
| Vault before enforcing PAM | Enforce PAM right after Warpgate works | Enforcement depends only on Warpgate |
| Wazuh ingests every source directly | LOG1 stays the single collector and forwards a copy; Wazuh agents add file integrity, configuration audit and command auditing | One pipeline, one source of truth; LOG1's format does not match Wazuh's decoders |
| Wazuh beside detection R1–R7 | Wazuh takes over R1–R5; LOG1 keeps R6 and R7 plus a new R8 (Wazuh feed silent) | No duplicate alert streams; the pipeline still watches itself |
| Management segment "if possible" | A dedicated **SEC** segment | The Wazuh VM must run outside EVE, and admin traffic must cross FW1 |
| pfSense administration through Warpgate | Kept with pfSense's existing RADIUS login; the firewall makes Warpgate the only path | No new login; pfSense keeps authorising |

### Update, 24 October 2026

Warpgate v0.30.0 (released 19 October) added a Vault secret backend and **Vault-signed SSH
certificates** for SSH targets: Warpgate can now log in to a server with a short-lived
certificate signed by Vault for each connection. The first correction above was true when
it was written and is now out of date. The design changes as follows:

- Extension Phase 2 still builds Warpgate with its own static key, so the privileged path
  works before Vault exists.
- Extension Phase 4 then moves Warpgate's targets to Vault-signed certificates and removes
  the static key. Humans still never hold a server credential; Warpgate's own standing
  credential disappears too.

## Abandoned design

Warpgate installed in the IT segment at 10.10.30.30: traffic between IT1 and a gateway in
the same segment never crosses FW1, so pfSense could neither filter nor log it. Replaced by
the SEC segment before anything was installed.

## Decisions taken by the project owner

| Decision | Choice |
|---|---|
| SEC segment | Approved: 7th FW1 interface plus VMware VMnet3 |
| Secrets manager | HashiCorp Vault Community |
| Wazuh dashboard login | Keycloak SSO; the local Wazuh admin is break-glass only |
| Infrastructure administration | Only through Warpgate |
| AI provider | Decided at Extension Phase 8 |

## Each control answers one question

| Control | Question |
|---|---|
| pfSense | Which network flows are permitted? |
| Keycloak | Who is this person? |
| oauth2-proxy + nginx | May this user reach this application from here? |
| OpenVPN + FreeRADIUS + PKI/CRL | May this remote device and user join the network? |
| Warpgate | May this administrator open a session on this infrastructure resource, and what did they do? |
| Vault | How are machine and break-glass secrets stored, issued, limited in time, revoked and audited? |
| LOG1 | What exactly happened? |
| Wazuh | Is something suspicious or policy-violating happening? |
| AI triage | What happened, what supports it, and what should the analyst check next? |

## Extension roadmap

| Phase | Content | State |
|---|---|---|
| 0 | Baseline: repository, sanitised exports, host identity check | Done ([09-ext-phase-0-baseline.md](09-ext-phase-0-baseline.md)) |
| 1 | SEC segment and PAM1 base host | Done ([10-ext-phase-1-sec-segment.md](10-ext-phase-1-sec-segment.md)) |
| 2A | Warpgate on PAM1: Keycloak SSO, role `ops`, first SSH target, recording | Done ([11-ext-phase-2a-warpgate.md](11-ext-phase-2a-warpgate.md)) |
| 2B | Part 1: other SSH targets, approvals, tickets evaluated ([12-ext-phase-2b-targets-approvals.md](12-ext-phase-2b-targets-approvals.md)); part 2: web targets ([13-ext-phase-2b-web-targets.md](13-ext-phase-2b-web-targets.md)) | Done |
| 3 | Enforce PAM: remove direct SSH and GUI paths | Not started |
| 4 | Vault on VAULT1: KV secrets, SSH CA (Warpgate targets and the backup job), break-glass, Transit | Not started |
| 5 | Encrypted backups, signed log manifests, restore drill | Not started |
| 6 | Audit integration: Warpgate, Vault, sudo, auditd into LOG1; feed to Wazuh | Not started |
| 7 | Wazuh VM: agents, decoders, rules | Not started |
| 8 | AI triage, advisory only | Not started |
| 9 | Validation: full scenario catalogue, recorded evidence | Not started |
