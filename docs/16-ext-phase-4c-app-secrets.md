# Extension Phase 4C: AppServer's secrets in Vault, delivered by Vault Agent

**Date:** 1 November 2026. **Commit:** the commit that adds this file. **State:** done.
Previous part: [15-ext-phase-4ab-vault.md](15-ext-phase-4ab-vault.md).

## Goal

The six secrets of AppServer's compose project (`DB_PASSWORD`, `KC_ADMIN_PASSWORD`,
`HR_CLIENT_SECRET`, `HR_COOKIE_SECRET`, `FIN_CLIENT_SECRET`, `FIN_COOKIE_SECRET`) were stored in
plain text in `~/ztna/.env`. They now live in Vault, are delivered to AppServer by Vault Agent
with a machine identity that works from AppServer only, exist on AppServer only in memory, and
can be rotated from Vault with the change reaching the application automatically.

```text
Vault (VAULT1)  secret/appserver/compose (KV v2, versioned)  ◄── administrators (OIDC), audited
      ▲  read-only, from 172.16.0.10 only
      │  AppRole "appserver"
Vault Agent on AppServer ──► /run/vault-agent/compose.env (tmpfs, root, 0600)
                                   ▲ symbolic link
                         ~/ztna/.env ──► docker compose
```

## Vendor facts checked before the work

| Source | Fact | Used for |
|---|---|---|
| Vault docs, Agent templates | A `template` stanza takes `source`, `destination`, `perms` and an `exec` block (`command` list, `timeout`); KV v2 secrets are re-read every `static_secret_render_interval` (default 5 min) | Rendering and `docker compose up -d` on change; interval 1 min |
| Vault docs, AppRole | `vault read …/role-id`, `vault write -f …/secret-id`; logins can be restricted to CIDR ranges | Machine identity bound to AppServer's address |

## Design decisions

| Decision | Reason |
|---|---|
| One KV v2 entry `secret/appserver/compose` | Single source of truth; every version kept with who wrote it |
| Policy `appserver-compose`: `read` on that path only | Least privilege for the machine |
| AppRole `appserver`: `secret_id_bound_cidrs` and `token_bound_cidrs` = `172.16.0.10/32`, token 1 h (max 4 h), secret-id without expiry | The credential is useless from any other address; the Agent can restart on its own; revocation if ever exposed |
| Rendered file in tmpfs (`/run/vault-agent`, systemd `RuntimeDirectory`, mode 0700), `~/ztna/.env` a link to it | The secrets are no longer at rest on AppServer's disk; they vanish when the Agent stops and are rendered again at start |
| Agent runs `docker compose up -d` after each render | A rotation in Vault reaches the application without a manual step; compose recreates only the containers whose configuration changed |
| No secret displayed during the migration | Values moved by `sudo cat … \| python3 … \| vault kv put … -`; identifiers by `vault … \| sudo tee`; only key names printed |
| Administrator token never left on AppServer | Used for the migration only, then `vault token revoke -self` |

## What was done

### Network

| Item | Value |
|---|---|
| FW1 DMZ rule | `APP_SERVER → VAULT_SERVER:8200`, logged, "AppServer to Vault (Agent)" |
| VAULT1 ufw | `8200` from `172.16.0.10` ("Vault API from AppServer (Agent)") |
| FW1 SEC rule description | Corrected to "VAULT1 to Keycloak (OIDC)" |

### Vault

| Item | Value |
|---|---|
| Secrets engine | KV version 2 at `secret/` |
| Secret | `secret/appserver/compose`, 6 keys; version 1 created by `oidc-itadmin@ztna.lab` |
| Policy `appserver-compose` | `path "secret/data/appserver/compose" { capabilities = ["read"] }` |
| Auth method | AppRole at `approle/`; role `appserver` as above |
| Secret-ids | One, accessor `ed89a41d-6343-f1c7-99d5-7f001e672e5f` (created 18:06:43); the test one from T5 destroyed |

### AppServer

| Item | Value |
|---|---|
| Vault binary | 2.2.1, same signature and hash check as on VAULT1 |
| `/etc/vault-agent/` | `role-id`, `secret-id` (root, 0600, not exported), `agent.hcl`, `compose.env.ctmpl` |
| Template | Writes every key of the secret (`range` over `.Data.data`), so new keys need no template change |
| Unit `vault-agent.service` | `vault agent -config=/etc/vault-agent/agent.hcl`, after and requiring `docker.service`, `RuntimeDirectory=vault-agent` |
| `~/ztna/.env` | Symbolic link to `/run/vault-agent/compose.env` (recorded in `SYMLINKS.txt`) |
| Plaintext backup of the old `.env` | Kept in `/root` during the change, then deleted with `shred -u` |

## Tests

| # | Test | Expected | Evidence |
|---|---|---|---|
| 1 | AppServer → Vault health endpoint over TLS | `initialized:true, sealed:false` | **Verified** |
| 2 | Vault download on AppServer | `Good signature`, hash `OK` | **Verified** |
| 3 | Role `appserver` | CIDRs, policy, TTL as designed | **Verified** |
| 4 | Migration of `.env` into Vault | Version 1, the six key names, no value displayed | **Verified** |
| 5 | Resolved compose configuration identical before and after (hash H1 = H2) | Equal | Reported |
| T1 | Containers after the switch | Not recreated | **Verified** (created 3 weeks / 27 hours earlier, still up) |
| T2 | HR application and Warpgate login | Work | Reported |
| T3 | `~/ztna/.env` | Link to `/run/vault-agent/compose.env` | **Verified** |
| T4 | Agent login in Vault's audit log | AppRole entry | **Verified** (`display_name approle`) |
| T5 | Valid role-id and secret-id used from VAULT1 | Refused | **Verified**: `400 source address "127.0.0.1" unauthorized by CIDR restrictions on the role` |
| T6 | Test secret-id removed; Agent still authenticates with its own | One secret-id left; `authentication successful` | Agent re-login **Verified** (18:23:30); destruction reported |
| R1 | Rotation of `HR_CLIENT_SECRET`: Keycloak regenerated, Vault updated | Version 2 | **Verified**: version 2 at 18:29:07, `created_by` `oidc-itadmin@ztna.lab`, operation `update` |
| R2 | Agent picks up the change | Re-render and `docker compose up -d` | **Verified**: rendered 18:29:52 (45 s after the update); `ztna-hr-proxy-1 Recreate` → `Started` 18:29:55; db, keycloak, hr-app, fin-app, fin-proxy `Running` |
| R3 | Only `hr-proxy` recreated | Others unchanged | **Verified**: `hr-proxy` created 47 s earlier; `fin-proxy` 3 weeks, `keycloak` 27 hours |
| R4 | HR login with the new secret | Works | Reported |

The rotation window (HR logins refused between the Keycloak regeneration and the recreated
`hr-proxy`) was at most the time from the regeneration to 18:29:55; the regeneration time
itself was not recorded.

## Findings

- **KV v2 records who changed a secret.** Each version carries `created_by` with the person's
  OIDC identity, without reading the audit log.
- **`vault kv patch` warned that `vault-admin` lacks the `patch` capability** on `secret/*` and
  fell back to read-then-write. Add `patch` to that path of the policy at the next policy change.
- **One OIDC token copied into two sessions is one credential.** Revoking it at the end of the
  AppServer migration also logged the administrator out of VAULT1 and the UI (seen at T5).
- AppServer's compose operations now need `sudo` and a running Agent: without the Agent, the
  link points to nothing and `docker compose` cannot resolve the variables (running containers
  are not affected).
