# Links

Every address used in the project: the lab's own web interfaces and endpoints, the
repository, and the external documentation each phase relied on.

Lab names (`*.ztna.lab`) resolve only through FW1's DNS resolver, so they work from inside
the lab or over the VPN, not from the open internet.

## 1. Lab: management interfaces

| Interface | Address | Reachable from | Login |
|---|---|---|---|
| EVE-NG web UI | `http://192.168.78.10` | Windows host | EVE-NG account |
| Serial consoles (PuTTY, Telnet) | `192.168.78.10`, port `32768 + node ID` | Windows host | Node account (`labadmin`) |
| pfSense web GUI | `https://192.168.78.20` | `ADMIN_PC` (192.168.78.1) on the WAN | RADIUS (itadmin + code); local `admin` is break-glass |
| pfSense web GUI | `https://10.10.30.1` | IT segment (anti-lockout rule) | Same |
| Keycloak admin console | `https://auth.ztna.lab/admin/` | IT1 (10.10.30.10) and `VPN_IT` only (nginx rule) | `kcadmin` + OTP (master realm) |
| Warpgate admin UI | `https://pam.ztna.lab/@warpgate/admin` | IT1 and `VPN_IT` (FW1 + ufw) | Local `admin` (break-glass); `secops` (approver role) |
| pfSense GUI through Warpgate | `https://fw1.pam.ztna.lab` | IT1 and `VPN_IT`, Warpgate role `ops` | Warpgate SSO, then RADIUS (itadmin + code) |
| Keycloak admin console through Warpgate | `https://kcadmin.pam.ztna.lab/admin/` | IT1 and `VPN_IT`, Warpgate role `ops` | Warpgate SSO, then `kcadmin` + OTP |

| Vault UI through Warpgate | `https://vault.pam.ztna.lab` | IT1 and `VPN_IT`, Warpgate role `ops` | Warpgate SSO, then Vault method OIDC (Keycloak, group `it-admins`) |
| Backup restore (Vault UI) | `https://vault.pam.ztna.lab/ui/vault/secrets-engines/transit/show/backup-kek` | As above | OIDC with Role `backup-restore` (30 min), then Key actions → Decrypt |

**Planned:** the Wazuh dashboard at `https://wazuh.pam.ztna.lab` (Extension Phase 7).

## 2. Lab: user-facing services

| Service | Address | Allowed from | Login |
|---|---|---|---|
| HR application | `https://hr.ztna.lab` | HR segment, `VPN_HR` | Keycloak, group `hr` |
| Finance application | `https://fin.ztna.lab` | FIN segment, `VPN_FIN` | Keycloak, group `fin` |
| Warpgate (administrators) | `https://pam.ztna.lab/` | IT1, `VPN_IT` | Button "ZTNA Keycloak" (group `it-admins` → role `ops`) |
| Warpgate SSH entry point | `pam.ztna.lab`, port `2222`, user `<user>:<target>` | IT1, `VPN_IT` | Same identity, approved in the browser |
| OpenVPN | UDP `192.168.78.20:1194` (Windows), `10.10.40.1:1194` (REMOTE1) | `ADMIN_PC`, REMOTE segment | Certificate + RADIUS password + code |

## 3. Lab: protocol endpoints (configuration values)

| Endpoint | Value | Used by |
|---|---|---|
| Keycloak issuer, realm `ztna` | `https://auth.ztna.lab/realms/ztna` | oauth2-proxy (hr, fin), Warpgate |
| OIDC discovery document | `https://auth.ztna.lab/realms/ztna/.well-known/openid-configuration` | Test of the path to Keycloak (Extension Phase 2A, step 2.2) |
| HR redirect URI | `https://hr.ztna.lab/oauth2/callback` | Keycloak client `hr-app` |
| FIN redirect URI | `https://fin.ztna.lab/oauth2/callback` | Keycloak client `fin-app` |
| Warpgate redirect URI | `https://pam.ztna.lab/@warpgate/api/sso/return` | Keycloak client `warpgate` |
| RADIUS | `172.16.0.20`, UDP 1812 (auth), 1813 (accounting) | FW1 only |
| Syslog collector | `10.10.30.20`, UDP 514 (FW1), TCP 514 (AppServer, RADIUS1) | All senders |
| Time server | `192.168.78.10`, UDP 123 (EVE-NG chrony) | FW1 and every node |

## 4. Repository

| What | Address |
|---|---|
| Configuration repository (private) | <https://github.com/MoadhBn/ztna-lab-config> |
| Local copy | `C:\Users\moadh\Documents\ztna-lab-config` |

## 5. Downloads (pinned)

| Component | Version | Address | SHA-256 |
|---|---|---|---|
| Vault (linux_amd64 zip) | 2.2.1 | <https://releases.hashicorp.com/vault/2.2.1/vault_2.2.1_linux_amd64.zip> (`SHA256SUMS` signed by HashiCorp key `C874 011F 0AB4 0511 0D02 1055 3436 5D94 72D7 468F`) | `079435de8ff146bdec4cdbe3be71d672ef4e59e4df6af0f2dba672e71be21a68` |
| Warpgate (x86_64 Linux) | v0.30.0 | <https://github.com/warp-tech/warpgate/releases/download/v0.30.0/warpgate-v0.30.0-x86_64-linux> | `49f02781e4f6bd199aa9d29c0acd1fd90ef0c0627a76742d08adb8985c60096c` |

Container images are pinned by digest in `nodes/appserver/home/labadmin/ztna/docker-compose.yml`.

## 6. External documentation

### Standards and frameworks

| Document | Address | Used for |
|---|---|---|
| NIST SP 800-207, *Zero Trust Architecture* | <https://csrc.nist.gov/pubs/sp/800/207/final> | Reference model of the whole project |
| NIST SP 800-63B-4, *Authentication and Authenticator Management* | <https://pages.nist.gov/800-63-4/sp800-63b.html> | Keycloak password policy (length, no composition rules, no expiry) |
| CISA *Zero Trust Maturity Model* | <https://www.cisa.gov/zero-trust-maturity-model> | Evaluation of the result |
| BlastRADIUS (CVE-2024-3596) | <https://www.blastradius.fail/> | RADIUS `Message-Authenticator` hardening |

### Protocols (RFCs)

| RFC | Address |
|---|---|
| RFC 2865, RADIUS | <https://www.rfc-editor.org/rfc/rfc2865> |
| RFC 2866, RADIUS Accounting | <https://www.rfc-editor.org/rfc/rfc2866> |
| RFC 4226, HOTP | <https://www.rfc-editor.org/rfc/rfc4226> |
| RFC 6238, TOTP | <https://www.rfc-editor.org/rfc/rfc6238> |
| RFC 5280, X.509 certificates and CRLs | <https://www.rfc-editor.org/rfc/rfc5280> |
| RFC 6749, OAuth 2.0 | <https://www.rfc-editor.org/rfc/rfc6749> |
| RFC 7636, PKCE | <https://www.rfc-editor.org/rfc/rfc7636> |
| RFC 5424, Syslog | <https://www.rfc-editor.org/rfc/rfc5424> |
| OpenID Connect Core 1.0 | <https://openid.net/specs/openid-connect-core-1_0.html> |

### Product documentation (original build)

| Product | Address |
|---|---|
| pfSense | <https://docs.netgate.com/pfsense/en/latest/> |
| FreeRADIUS | <https://www.freeradius.org/documentation/> |
| Keycloak | <https://www.keycloak.org/documentation> |
| Keycloak hostname options | <https://www.keycloak.org/server/hostname> |
| Keycloak admin recovery (`bootstrap-admin`) | <https://www.keycloak.org/server/bootstrap-admin-recovery> |
| oauth2-proxy | <https://oauth2-proxy.github.io/oauth2-proxy/> |
| rsyslog | <https://www.rsyslog.com/doc/> |
| lnav | <https://docs.lnav.org/> |

### Warpgate (Extension Phase 2)

| Page | Address | Used for |
|---|---|---|
| Source code and releases | <https://github.com/warp-tech/warpgate> | Release choice |
| v0.30.0 release notes | <https://github.com/warp-tech/warpgate/releases/tag/v0.30.0> | Vault-signed SSH certificates, security fixes |
| Getting started (native) | <https://warpgate.null.page/getting-started/> | Install, setup, ports |
| Systemd service | <https://warpgate.null.page/systemd/> | Service unit |
| Single sign-on | <https://warpgate.null.page/sso/> | Keycloak provider, `roles_claim`, `role_mappings`, linking by email |
| User authentication | <https://warpgate.null.page/auth/> | Credential policies, in-browser approval for SSH |
| User roles | <https://warpgate.null.page/roles/> | Access roles and admin roles |
| SSH targets | <https://warpgate.null.page/targets/ssh/> | Client keys, host key verification, command auditing |
| Custom root CAs | <https://warpgate.null.page/custom-ca/> | Trusting ZTNA-Lab-CA (host trust store) |
| Session recordings | <https://warpgate.null.page/recordings/> | Recording is a UI setting, not a config key |
| TLS SNI | <https://warpgate.null.page/sni/> | `http.certificate` / `http.key` keys for the lab certificate |
| HTTP targets | <https://warpgate.null.page/targets/http/> | Target URL, certificate verification, domain binding |
| HTTP domain binding | <https://warpgate.null.page/http-domain-binding/> | `fw1.pam.ztna.lab`, `kcadmin.pam.ztna.lab` |
| Session approvals | <https://warpgate.null.page/approvals/> | Per-session approval for RADIUS1 (Extension Phase 2B) |
| Access tickets | <https://warpgate.null.page/tickets/> | Time-limited access (Extension Phase 2B) |
| Secret backends (Vault) | <https://warpgate.null.page/secret-backends/> | Backend `vault`, AppRole, allowed prefixes |
| Recovering admin access | <https://warpgate.null.page/recovering-access/> | `warpgate recover-access` |
| Production checklist | <https://warpgate.null.page/production-checklist/> | Hardening review |

### Vault (Extension Phase 4)

| Page | Address | Used for |
|---|---|---|
| Install | <https://developer.hashicorp.com/vault/install> | Version |
| HashiCorp security (PGP key) | <https://www.hashicorp.com/en/trust/security> | Download verification |
| Integrated storage (raft) | <https://developer.hashicorp.com/vault/docs/configuration/storage/raft> | Configuration |
| JWT/OIDC auth method | <https://developer.hashicorp.com/vault/docs/auth/jwt> | Keycloak login, role, redirect URI |
| Agent templates | <https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/template> | Vault Agent on AppServer |
| AppRole | <https://developer.hashicorp.com/vault/docs/auth/approle> | Machine identities `appserver`, `warpgate` |
| Signed SSH certificates | <https://developer.hashicorp.com/vault/docs/secrets/ssh/signed-ssh-certificates> | CA for Warpgate's targets |
| generate-root API | <https://developer.hashicorp.com/vault/api-docs/system/generate-root> | Conditionally unauthenticated in 2.x |
| Transit API | <https://developer.hashicorp.com/vault/api-docs/secret/transit> | `backup-kek` (RSA-OAEP decrypt), `manifest-sign` (Ed25519 sign/verify) (Phase 5) |
| SSH secrets engine API | <https://developer.hashicorp.com/vault/api-docs/secret/ssh> | Role `backup`: critical options and their defaults (Phase 5) |
| Raft storage API | <https://developer.hashicorp.com/vault/api-docs/system/storage/raft> | Snapshot taken by the backup job (Phase 5) |
| OpenSSH `sshd_config` | <https://man.openbsd.org/sshd_config> | `AuthorizedPrincipalsFile` with `from=`/`command=` (Phase 5) |
| Server configuration | <https://developer.hashicorp.com/vault/docs/configuration> | `enable_unauthenticated_access` |

### Tool selection

| Page | Address | Used for |
|---|---|---|
| Teleport feature matrix | <https://goteleport.com/docs/feature-matrix> | Why Teleport Community was rejected (OIDC is Enterprise-only) |
| HashiCorp: SSH access with Vault and Boundary | <https://www.hashicorp.com/blog/secure-ssh-access-at-scale-with-hashicorp-vault-and-boundary> | Vault SSH certificate pattern |
