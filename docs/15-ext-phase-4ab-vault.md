# Extension Phase 4A and 4B: Vault on VAULT1, administrator login through Keycloak

**Date:** 1 November 2026. **Commit:** the commit that adds this file. **State:** done.
Previous phase: [14-ext-phase-3-enforce-pam.md](14-ext-phase-3-enforce-pam.md).

Extension Phase 4 is split in four parts: **4A** the Vault server, **4B** administrator access
(this file), 4C application secrets with Vault Agent, 4D SSH certificates for Warpgate's
targets, break-glass secrets and Transit.

## Goal

A secrets manager on its own host in the SEC segment, reachable by administrators only
through Warpgate and only with their Keycloak identity, with an audit trail from the first
minute and no standing root credential.

```text
itadmin ─► https://vault.pam.ztna.lab ─► Warpgate target vault-ui ─► https://vault.ztna.lab:8200 (VAULT1, 10.10.60.20)
                                                                       │ login method "oidc"
                                                                       ▼
                                        Keycloak realm ztna, client "vault", group it-admins
```

## Vendor facts checked before the work

| Source | Fact | Used for |
|---|---|---|
| HashiCorp install page | Latest Vault Community version 2.2.1 | Version installed, pinned |
| HashiCorp security page | `SHA256SUMS` is signed with PGP key `C874 011F 0AB4 0511 0D02 1055 3436 5D94 72D7 468F`; archives are only hashed | Signature check, then hash check |
| `releases.hashicorp.com`, `vault_2.2.1_SHA256SUMS` | `vault_2.2.1_linux_amd64.zip` = `079435de8ff146bdec4cdbe3be71d672ef4e59e4df6af0f2dba672e71be21a68` | Reference value |
| Vault docs, integrated storage | Single node needs `storage "raft"` (`path`, `node_id`) and `cluster_addr`; `disable_mlock = true` recommended, with swap off | Configuration |
| Vault docs, JWT/OIDC auth | UI redirect `https://{host:port}/ui/vault/auth/{path}/oidc/callback`; `bound_claims` can only be written with the whole role as JSON; `vault login -method=oidc` needs a callback on `localhost:8250` | OIDC configuration; CLI work uses a token copied from the UI |

The signed zip was chosen over HashiCorp's apt repository: it does not depend on the
repository supporting Ubuntu 26.04, it pins the exact version, and it is the same method as
for Warpgate.

## Design decisions

| Decision | Reason |
|---|---|
| VAULT1 in SEC (10.10.60.20) | Tier-0 service; flows from other segments cross FW1. Flows with PAM1 stay inside SEC and are filtered by VAULT1's ufw |
| Built without direct SSH | Serial console until the Warpgate target `vault1` existed, then Warpgate only (Phase 3 rule) |
| Target `vault1` with approval | Root on VAULT1 controls every secret |
| Initialisation on the serial console, PuTTY logging off | Warpgate records sessions; the unseal keys and the root token must never appear in a recording |
| Shamir, 5 keys, threshold 3 | No single key unseals Vault; losing two keys is survivable |
| Audit device enabled before anything else | Every later operation is in the audit log |
| Policy `vault-admin` denies `sys/audit/*` | An administrator cannot switch off the audit trail; only a root token regenerated from 3 unseal keys can |
| OIDC role `it-admins`: `bound_claims` groups = `it-admins`, `user_claim` = `email`, token 1 h (max 8 h) | Only that Keycloak group; audit entries name the person (`oidc-itadmin@ztna.lab`); short-lived tokens |
| Initial root token revoked once OIDC worked | No standing root credential; `vault operator generate-root` with 3 unseal keys is the break-glass path |
| Vault UI on its own Warpgate address `vault.pam.ztna.lab`, no approval | Same pattern and limitation as the other web consoles; the SSH target keeps approval |
| Warpgate certificate reissued with `vault.pam.ztna.lab` and `wazuh.pam.ztna.lab` | Phase 7 needs the Wazuh name; one reissue instead of two |

## What was done

### VAULT1 (EVE node, 1 GB RAM, 1 vCPU, SEC)

| Item | Value |
|---|---|
| Identity | Host name `vault1`; new SSH host keys (`i2DtH3S5vITMrdqF+7raTSUrIQHrFs9bM3NoKL/OOMY`) and machine-id (`92fd22036ff945de8e5e9b892cbb5af7`), distinct from every other node |
| Network | One netplan file, static `10.10.60.20/24`, gateway and DNS `10.10.60.1`; cloud-init disabled |
| Time | chrony, single source `192.168.78.10` |
| SSH | Key-only (`00-ztna-hardening.conf`); `pamops` with Warpgate's key `from="10.10.60.10"`; `labadmin` has no SSH key |
| ufw | `22` and `8200` from `10.10.60.10` only |
| Swap | Off (`/etc/fstab` entry commented) |
| Lab CA | In the system trust store (fingerprint `B8:46:89:…:64:2B`) |
| Vault | 2.2.1 at `/usr/local/bin/vault`, account `vault` (system, no shell), unit `vault.service` (`Type=notify`, `ProtectSystem=full`, `NoNewPrivileges`) |
| Configuration | `/etc/vault.d/vault.hcl`: UI on, raft at `/var/lib/vault/data` (node `vault1`), listener `0.0.0.0:8200` with TLS 1.2+, `api_addr https://vault.ztna.lab:8200` |
| TLS | Key and CSR made on VAULT1 (`vault.key` mode 640 `root:vault`); certificate `vault-web` from the lab CA, SAN `vault.ztna.lab`, `10.10.60.20`, `127.0.0.1` |
| Audit | File device `file/` → `/var/log/vault/audit.log`; secret values appear only as `hmac-sha256:` hashes |

### Vault configuration

| Item | Value |
|---|---|
| Seal | Shamir, 5 shares, threshold 3; keys only in the operator's password manager |
| Auth method `oidc/` | Discovery `https://auth.ztna.lab/realms/ztna`, client `vault`, default role `it-admins`; client secret entered from a hidden prompt |
| Role `it-admins` | `role_type oidc`, `user_claim email`, `groups_claim groups`, `bound_audiences vault`, `bound_claims {"groups":["it-admins"]}`, redirect `https://vault.pam.ztna.lab/ui/vault/auth/oidc/oidc/callback`, scopes `openid email profile`, policy `vault-admin`, TTL 1 h, max 8 h |
| Policy `vault-admin` | Administration of auth methods, policies, identity, mounts, leases, `secret/`, `ssh-client-signer/`, `transit/`; `sys/audit/*` and `sys/audit-hash/*` denied |
| Root token | Revoked |

### Keycloak (realm `ztna`)

Confidential client `vault`, standard flow only, redirect URI and web origin on
`vault.pam.ztna.lab`, Group Membership mapper `groups` (full path off).

### FW1

| Item | Value |
|---|---|
| SEC rule | `VAULT_SERVER → APP_SERVER:443`, logged (description typed `VAULT1 to Keycloadk (OIDC)`) |
| DNS host overrides | `vault.pam.ztna.lab` and `wazuh.pam.ztna.lab` → `10.10.60.10` (Warpgate); `vault.ztna.lab` → `10.10.60.20` unchanged |
| Certificates | `vault-web` (VAULT1); `pam-web-4b` (Warpgate, five names); `pam-web-2b` deleted |

### PAM1 and Warpgate

| Item | Value |
|---|---|
| Certificate | New key and CSR on PAM1 (`pam-4b.csr`), SAN `pam`, `kcadmin.pam`, `fw1.pam`, `vault.pam`, `wazuh.pam` (`.ztna.lab`), valid to 4 December 2027; the 2B key deleted |
| Target `vault1` | SSH `10.10.60.20:22`, `pamops`, ed25519 key, role `ops`, approval |
| Target `vault-ui` | HTTP `https://vault.ztna.lab:8200`, certificate verified, bound to `vault.pam.ztna.lab`, role `ops` |

## Tests

| # | Test | Expected | Evidence |
|---|---|---|---|
| 1 | Vault download | Signature by `C874…468F`, hash OK | Reported |
| 2 | `hostname; vault version` | `vault1`, `Vault v2.2.1` | **Verified** |
| 3 | `vault status` | Initialized, unsealed, shamir 5/3, raft | **Verified** |
| 4 | File permissions, swap, ufw | `vault.key` 640 `root:vault`; no swap; `22`, `8200` from `10.10.60.10` only | **Verified** |
| 5 | VAULT1 → Keycloak discovery document | `200` | **Verified** |
| 6 | Warpgate certificate | Five names, verifies against the lab CA | **Verified** in the PAM1 export (signing step itself reported) |
| 7 | `itadmin` logs in to the Vault UI with OIDC at `vault.pam.ztna.lab` | Dashboard | **Verified** (Vault v2.2.1 dashboard, Warpgate badge) |
| 8 | OIDC token | `display_name oidc-itadmin@ztna.lab`, policies `default vault-admin`, TTL 1 h | **Verified** |
| 9 | `vault audit disable file/` with the OIDC token | `permission denied` | **Verified** (`403`) |
| 10 | Audit trail of the OIDC login | Entry with `display_name oidc-itadmin@ztna.lab`, HMAC-ed token | **Verified** |
| 11 | Root token revoked | Login with it refused | **Verified** (`403 permission denied, invalid token`) |
| 12 | sofien | Refused | **Verified at Warpgate** ("No user matching sofien@ztna.lab"); Vault's own refusal of a user outside `it-admins` was not tested |
| 13 | Warpgate's pinned host key for `vault1` = `i2DtH3S5…` | Matches | Not recorded |

## Problems met and findings

| Item | Detail |
|---|---|
| The prompt still showed `ubuntu-base` | The shell predated the rename; the identity check confirmed new host keys and machine-id |
| `vault login` prints the token | It printed the root token (just before its revocation) in a recorded Warpgate session. Use `vault login -no-print` in recorded sessions from now on |
| FW1 rule description typo | `Keycloadk`; correct with the next FW1 change |

## Operations and break-glass

- After every restart of VAULT1, Vault starts sealed: 3 unseal keys on the serial console.
- New root token if ever needed: `vault operator generate-root` with 3 unseal keys on the
  serial console, used for the task, then revoked.
- Administrators work in the UI; for the CLI they copy their OIDC token from the UI and run
  `vault login -no-print` in a `vault1` session.
