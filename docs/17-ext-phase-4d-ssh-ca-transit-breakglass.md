# Extension Phase 4D: Vault-signed SSH certificates, Transit, break-glass secrets

**Date:** 2 and 3 November 2026. **Commit:** the commit that adds this file. **State:** done;
the root-generation ceremony was not recorded end to end (see Tests).
Previous part: [16-ext-phase-4c-app-secrets.md](16-ext-phase-4c-app-secrets.md).

## Goal

Warpgate no longer holds a standing credential for the servers. Instead of one permanent key
trusted by `pamops` on five servers, Warpgate obtains a 5-minute certificate from Vault for each
session, and the servers trust only Vault's SSH certificate authority. Vault also gets the
Transit key used by the Phase 5 backups and stores the break-glass passwords so that reading
them is a ceremony.

```text
itadmin ─► Warpgate (PAM1) ── AppRole "warpgate" (from 10.10.60.10 only) ─► Vault: ssh-client-signer/sign/warpgate
                │                                                            │ 5-minute Ed25519 certificate
                │ ◄──────────────────────────────────────────────────────────┘ principal pamops, source-address PAM1
                └─► pamops@target  (sshd: TrustedUserCAKeys /etc/ssh/warpgate_ca.pub; authorized_keys empty)
```

## Vendor facts checked before the work

| Source | Fact | Used for |
|---|---|---|
| Warpgate, *Secret backends* (v0.30+) | Backends in *Config → Secret backends*, Vault address plus AppRole; *Allowed path prefixes*; audit events `SshCertificateIssued` | Backend `vault` restricted to `ssh-client-signer/sign/warpgate` |
| Warpgate, *SSH targets* | 5-minute Ed25519 certificate with key ID `warpgate:<user>:<session>`; role needs `allow_user_key_ids`, `allowed_users`, `permit-pty`, `max_ttl ≥ 5m`; token needs `update` on `<mount>/sign/<role>`; servers trust the CA with `TrustedUserCAKeys` | Vault role and policy; sshd drop-in |
| Vault, *Signed SSH certificates* | CA created with `config/ca`; public key readable without login | Distribution of the CA public key |
| Vault 2.x API, *generate-root* | `/sys/generate-root/attempt` is "conditionally unauthenticated": only if `enable_unauthenticated_access` includes `generate-root` | Configuration change below |
| Vault 2.x configuration | `enable_unauthenticated_access`: string list, default `[]`, values `rekey`, `generate-root`, `generate-operation-token`; reloadable with SIGHUP | Enabled for `generate-root` only, by reload |

## Design decisions

| Decision | Reason |
|---|---|
| Mount `ssh-client-signer`, role `warpgate`: `allowed_users`/`default_user` `pamops`, `permit-pty`, `ttl 5m`, `max_ttl 10m` | Certificates only for the brokered account, short-lived |
| Critical option `source-address 10.10.60.10/32,127.0.0.1/32` on every certificate | Keeps the protection the static key had with `from=`: a certificate is useless from anywhere but PAM1 (and PAM1 to itself) |
| AppRole `warpgate`, bound to `10.10.60.10/32`, policy `warpgate-ssh` (`update` on `ssh-client-signer/sign/warpgate` only) | Warpgate can sign and do nothing else, and only from PAM1 |
| Secret-id displayed only on VAULT1's serial console | Never in a recorded session |
| One server at a time: certificate, test, then remove the static key | Never lock out more than one server |
| Break-glass entries write-only for administrators; reading needs a root token from 3 unseal keys | Using an emergency password is a ceremony, not a lookup; it works when Keycloak is down |
| `enable_unauthenticated_access = ["generate-root"]` | Vault 2.x requires a login to start root generation by default, which would make the ceremony impossible exactly when Keycloak or OIDC is broken. Completing it still needs 3 unseal keys; port 8200 is reachable only from PAM1, AppServer and VAULT1 itself |
| Transit key `backup` (aes256-gcm96), not exportable, deletion not allowed | Phase 5 encrypts backups with a key that never leaves Vault |

## What was done

### Vault

| Item | Value |
|---|---|
| Policy `vault-admin` | Rewritten: `patch` added on `secret/*`; `secret/data/breakglass/*` create and update only; `secret/metadata/breakglass/*` read and list; delete and destroy on break-glass denied; audit devices still denied |
| SSH engine | `ssh-client-signer/`, CA generated (ed25519), public key fingerprint `SHA256:HGlS7uRA5x9oWSaJzwIJOAdRTa40S+pJTQvl2r3lyZQ` |
| Role `warpgate` | As above |
| Policy `warpgate-ssh` | `update` on `ssh-client-signer/sign/warpgate` |
| AppRole `warpgate` | Role-id `14f9c2b8-2fcb-c2f3-81bf-8629ea2c5c0e`; secret-id and token bound to `10.10.60.10/32`; token 1 h (max 4 h) |
| Transit | Engine `transit/`, key `backup` |
| Break-glass entries | `secret/breakglass/pfsense-admin`, `warpgate-admin`, `keycloak-kcadmin`, `labadmin-console` (each version 1, 2 November 11:56–11:58 UTC) |
| Configuration | `enable_unauthenticated_access = ["generate-root"]` in `vault.hcl`, applied with `systemctl reload vault` (no reseal) |

### Warpgate

| Item | Value |
|---|---|
| Secret backend `vault` | `https://vault.ztna.lab:8200`, AppRole, allowed prefix `ssh-client-signer/sign/warpgate` |
| Targets `appserver`, `radius1`, `log1`, `vault1`, `pam1` | Authentication "Certificate signed by a secret backend's SSH CA", backend `vault`, mount `ssh-client-signer`, role `warpgate` |
| Warpgate's own client key | Still present in Warpgate, trusted by no server |

### The five servers

| Item | Value |
|---|---|
| `/etc/ssh/warpgate_ca.pub` | Vault CA public key, fingerprint `HGlS7uRA…` on all five |
| `/etc/ssh/sshd_config.d/10-warpgate-ca.conf` | `TrustedUserCAKeys /etc/ssh/warpgate_ca.pub` |
| `pamops`'s `authorized_keys` | Empty (0 bytes) on all five |
| Export list | `warpgate_ca.pub` added |

## Tests

| # | Test | Expected | Evidence |
|---|---|---|---|
| 1 | Certificate login on AppServer before removing the key | `ED25519-CERT … ID warpgate:… CA … HGlS7uRA…` | **Verified** (2 November 12:34:37) |
| 2 | Same on RADIUS1, LOG1, VAULT1 (from `10.10.60.10`) and PAM1 (from `127.0.0.1`) | Same | **Verified** (12:47:28–12:47:33) |
| 3 | Five servers: CA fingerprint, `TrustedUserCAKeys`, empty `authorized_keys` | As designed | **Verified** (`0 /home/pamops/.ssh/authorized_keys` on all five; also in the exports) |
| 4 | Test certificate content (CA, 5 min, `Principals: pamops`, `source-address`, `permit-pty`) | As designed | Reported |
| 5 | Transit round trip | `vault:v1:…`, then the original text | **Verified** (`transit test`) |
| 6 | Administrator reads a break-glass entry | `permission denied` | **Verified** (`403`) |
| 7 | Administrator lists break-glass entries | Names only | **Verified** (four names) |
| 8 | Root generation without login, before the configuration change | Refused in Vault 2.x | **Verified** (`403 permission denied` on `sys/generate-root/attempt`) |
| 9 | Root generation after the change, reading a break-glass username, revoking the root token | Works | Reported; the audit log shows calls to `sys/generate-root/attempt`, but the ceremony itself was not recorded |
| 10 | Exports through Warpgate with certificates | Archives downloaded | **Verified** (five archives, 3 November) |

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| After the static key was removed, RADIUS1, LOG1, VAULT1 and PAM1 refused Warpgate | Their Warpgate targets were still set to public-key authentication: their logins showed `ED25519 SHA256:ZyENO54S…`, not `ED25519-CERT` | Targets switched to the certificate method; logins then showed `ED25519-CERT`. Rule kept for the future: the key may only be removed after a login line containing `-CERT` |
| `vault operator generate-root -init` → `403 permission denied` | Vault 2.x no longer treats root generation as unauthenticated by default | `enable_unauthenticated_access = ["generate-root"]`, reload |
| 3 November: Warpgate "SSH certificate signing failed" | The lab had been stopped; Vault started sealed, so it could not sign | Unseal on VAULT1's serial console (3 keys). The recovery is the documented break-glass path |

## Findings

- **Vault sealed means no new privileged SSH session.** This is the price of removing every
  standing credential: Warpgate's web targets keep working, SSH targets need Vault. After a
  cold start of the lab, the first step is to unseal VAULT1 on its console. Suspending the
  EVE-NG VM instead of shutting it down keeps Vault unsealed.
- **The break-glass entries `keycloak-kcadmin` and `labadmin-console` were stored with
  `username=admin`.** Correct with `vault kv put` (administrators can replace them, not read
  them) using `kcadmin` and `labadmin`.
- **A vendor default tightened between versions** (root generation in Vault 2.x). The
  break-glass design had to state its requirement explicitly in the configuration rather than
  rely on the old behaviour.

## Operations

| Situation | Procedure |
|---|---|
| Cold start of the lab | VAULT1 serial console: `vault operator unseal` three times; then check `vault-agent` on AppServer |
| Break-glass password needed | VAULT1 serial console, PuTTY logging off: `vault operator generate-root -init`, three `vault operator generate-root` with unseal keys, `-decode` with the OTP, `vault login -no-print`, read the entry, `vault token revoke -self` |
| Warpgate's AppRole secret-id exposed | `vault write auth/approle/role/warpgate/secret-id-accessor/destroy …`, new secret-id from the console into the Warpgate backend |
