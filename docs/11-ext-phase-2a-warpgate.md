# Extension Phase 2A: Warpgate, Keycloak SSO, first SSH target

**Date:** 24 to 30 October 2026. **Commit:** `b31d53b` (evidence added in the next commit). **State:** done. Design context: [08-extension-design.md](08-extension-design.md).

Extension Phase 2 is split in two. **2A** builds the gateway and proves one complete
privileged path end to end. **2B** adds the other targets, approvals and the web targets.

## Goal

An administrator reaches a server only through Warpgate on PAM1 (10.10.60.10): logged in
with their Keycloak identity, never holding a server credential, and with the session
recorded.

```text
itadmin (VPN_IT or IT1)
   │  https://pam.ztna.lab (443)            FW1: VPN_IT / IT_ADMIN → PAM_SERVER:PORT_PAM
   ▼
Warpgate on PAM1 ── OIDC ──► Keycloak (auth.ztna.lab, realm ztna)   FW1: PAM1 → APP_SERVER:443
   │  password + OTP in Keycloak, group it-admins → Warpgate role ops
   │  Warpgate's own ed25519 key, user pamops                       FW1: PAM1 → APP_SERVER:22
   ▼
AppServer 172.16.0.10 (pamops: key only, from="10.10.60.10", sudo)
```

## Why this design

| Choice | Reason |
|---|---|
| Warpgate holds the server key, not the administrator | Nobody has a credential that works without the gateway; leaving the team means losing access in one place (Keycloak) |
| Login through Keycloak, no Warpgate passwords for administrators | The brief allows no new authentication system; OTP and the password policy are already in Keycloak |
| Group `it-admins` mapped to role `ops` at every login | Removing someone from the group in Keycloak removes their Warpgate access at the next login |
| Dedicated account `pamops` on the target | Every brokered login is distinguishable in the logs from labadmin's direct logins (removed in Extension Phase 3) |
| `from="10.10.60.10"` on the key | A copy of Warpgate's key is useless anywhere but on PAM1 |
| Host key verification `prompt`, checked against the inventory | Warpgate must not trust a server it has never verified |
| Static Warpgate key for now | The path works before Vault exists; replaced by Vault-signed certificates in Extension Phase 4 |

## What was done

### FW1 (pfSense)

| Item | Value |
|---|---|
| Alias `PAM_SSH_TARGETS` | `APP_SERVER RADIUS_SERVER LOG_SERVER` (used in 2B) |
| Alias `PORT_PAM` | `443 2222` |
| OpenVPN rule | `VPN_IT → PAM_SERVER:PORT_PAM`, logged, "VPN admins to PAM" |
| IT rule | `IT_ADMIN → PAM_SERVER:PORT_PAM`, logged, "IT1 to PAM" |
| SEC rule | `PAM_SERVER → APP_SERVER:443`, logged, "PAM1 to Keycloak (OIDC)" |
| SEC rule | `PAM_SERVER → APP_SERVER:22`, logged, "PAM1 brokered SSH" (destination becomes `PAM_SSH_TARGETS` in 2B) |
| SEC tab | Final rule named `Default deny SEC`; OpenVPN final rule named `Default deny VPN` |
| OpenVPN local networks | `172.16.0.0/24, 10.10.30.20/32, 10.10.60.10/32` (PAM1 route pushed to VPN clients) |
| Certificate `pam-web` | Signed by the lab CA from a CSR made on PAM1; CN and SAN `pam.ztna.lab`, valid to 26 November 2027 |

All rows **Verified** in `nodes/fw1/config-redacted.xml`.

### PAM1

| Item | Value |
|---|---|
| Warpgate | v0.30.0, `/usr/local/bin/warpgate`, SHA-256 `49f02781e4f6bd199aa9d29c0acd1fd90ef0c0627a76742d08adb8985c60096c`, checked against the release |
| Service | `warpgate.service`, `Type=notify`, `Restart=always`, runs as root |
| Configuration | `/etc/warpgate.yaml` (mode 600): `external_host: pam.ztna.lab`, HTTPS on 443, SSH on 2222, every other protocol disabled, `host_key_verification: prompt`, web session 30 minutes |
| TLS | Key and CSR made on PAM1 in `/etc/warpgate-tls/` (directory mode 700, key mode 600); the key never left PAM1. `http.certificate`/`http.key` point to `pam.crt`/`pam.key` |
| Lab CA | `ztna-lab-ca.crt` in the host trust store (same SHA-256 as the CA on AppServer) |
| SSO provider `keycloak` | Custom OIDC, issuer `https://auth.ztna.lab/realms/ztna`, scopes `email profile`, `roles_claim: groups`, `role_mappings: it-admins → ops`; the client secret is redacted in the repository |
| Data | Database `/var/lib/warpgate/db`; recordings `/var/lib/warpgate/recordings/<session id>/` |
| Host firewall (ufw) | 443 and 2222 from `10.10.50.48/28` (VPN_IT) and `10.10.30.10` (IT1); 22 from IT1 (build phase); 22 from `10.10.50.49` (temporary, exports) |

### Keycloak (realm `ztna`)

| Item | Value |
|---|---|
| Client `warpgate` | Confidential, standard flow only, redirect URI `https://pam.ztna.lab/@warpgate/api/sso/return` |
| PKCE | `S256` (reported) |
| User `itadmin@ztna.lab` | Already existed in the realm (group `it-admins`); not created for this phase |
| Mapper `groups` | Group Membership, full path off, so the claim says `it-admins`, not `/it-admins` |

### Warpgate objects (admin UI)

| Object | Value |
|---|---|
| Role | `ops` |
| User | `itadmin`, SSO credential linked by the verified e-mail `itadmin@ztna.lab` |
| Target `appserver` | `172.16.0.10:22`, user `pamops`, Warpgate's own ed25519 key, role `ops` |
| Session recording | On (*Config → Global parameters → Session recordings*), local storage. In v0.30 this is a UI setting, not a key in `warpgate.yaml` |

### AppServer

| Item | Value |
|---|---|
| Account `pamops` | No password; `authorized_keys` = Warpgate's key with `from="10.10.60.10"` |
| sudo | `/etc/sudoers.d/90-pamops`: `pamops ALL=(ALL) NOPASSWD: ALL` (mode 440) |
| ufw | 22 from `10.10.60.10`, comment "SSH from PAM1 (Warpgate)" |

## Tests

| Test | Expected | Evidence |
|---|---|---|
| itadmin logs in to Warpgate through Keycloak (password + OTP) | Logged in, role `ops` | **Verified** (session of 30 October in the Warpgate admin UI) |
| itadmin opens a shell on `appserver` through Warpgate | Works; Warpgate shows the session from `10.10.50.49` | **Verified** |
| Host key shown by Warpgate for AppServer | `SHA256:3q8re8pgfcEnn4hNU2wqFzoXajY3X/GhyOHvgeQF1H8`, the inventory value | **Verified** (fingerprint computed from the key Warpgate showed) |
| AppServer log on LOG1 | `Accepted publickey for pamops from 10.10.60.10 … ED25519 SHA256:ZyENO54S…` and the sudo line for `/usr/bin/id` | **Verified** (24 October) |
| Key in `pamops`'s `authorized_keys` | Fingerprint `ZyENO54SVtc/gM0crh22i8NtDICSDjCvlFL4SQhw4u0`, the one recorded in the inventory | **Verified** in the export |
| Command audit | Warpgate's session log lists `id` and `exit` with their times | **Verified** |
| Recording | One folder per session under `/var/lib/warpgate/recordings/`; replay plays in the admin UI | **Verified** (folders listed on PAM1; replay of the 16:22 session of 30 October played as `admin`) |
| Certificate served by Warpgate | Chain to the lab CA, name `pam.ztna.lab` | **Verified**: on PAM1 (`curl` with the system trust store reached HTTP, status 401 = not logged in; `openssl verify` of the exported certificate: OK) and in the Windows browser (no warning; issued to `pam.ztna.lab` by `ztna-lab-ca`; SHA-256 `3e2a97b4…824db6`, identical to the exported `pam.crt`) |
| `ssh -l pamops 172.16.0.10` from IT1 | `Permission denied (publickey)` | **Verified** |
| sofien (group `hr`, VPN 10.10.50.17) opens `https://pam.ztna.lab` | Blocked by FW1, block line on LOG1 | **Verified**: `filterlog … 1790519767,ovpns1,match,block,in,4 … tcp … 10.10.50.17,10.10.60.10,64842,443 … S` (30 October 18:29); tracker `1790519767` is the rule `Default deny VPN` |
| sofien authenticates in Keycloak and is sent to Warpgate (from an itadmin VPN connection) | Refused by Warpgate | **Verified**: "No user matching sofien@ztna.lab". Keycloak accepted the person; Warpgate refused because no Warpgate user is linked to that e-mail. Even with a user, the role mapping would give no role: sofien is not in `it-admins` |

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| `warpgate --version` failed | The subcommand is `version` | `warpgate version` |
| `warpgate setup` failed | The data directory did not exist | `sudo install -d -m 700 /var/lib/warpgate`, then setup again |
| SSO login: "No user matching itadmin@ztna.lab" | Warpgate links an SSO login to an existing Warpgate user by verified e-mail; with auto-create off it creates no user | The Warpgate user `itadmin` was created, with an SSO credential for `itadmin@ztna.lab` |
| The Keycloak client secret was typed on a command line once | It ended up in the shell history and the PuTTY log | Secret regenerated in Keycloak and the new value set in `warpgate.yaml` (reported); the old value left in the history and the log no longer works |
| Warpgate offered both ed25519 and RSA default keys | "Use default keys" lists both | The ed25519 key selected explicitly; it is the only key trusted on AppServer |
| The browser received Warpgate's self-signed certificate | `http.certificate`/`http.key` still pointed to the files generated by `warpgate setup` | Paths changed to `/etc/warpgate-tls/pam.crt` and `pam.key` in every protocol section, service restarted |
| The Warpgate web page reloaded in a loop after a restart | Not identified | Cleared without a configuration change |
| `/etc/warpgate.yaml` had no recording key | Since v0.30 recording is a global parameter stored in the database | Switched on in the admin UI |
| Six unencrypted full pfSense backups on the Windows host (Downloads and the repository folder, 24 September to 25 October) | Downloaded from *Backup & Restore* without the encryption box | Never committed (the repository folder is git-ignored since this phase). A new encrypted backup was made and all encrypted backups were moved to `C:\ztna-backups\`, outside the repository; the six plaintext files were deleted. The files never left the disk, so no key was rotated |
| The passphrase of the Windows export key `phase0-export` was lost | — | New key `ztna-export` (ED25519, passphrase in the password manager); old line removed from AppServer, new line added on AppServer and PAM1 with `from="10.10.50.49"` |

## Review of the exported configuration

| Finding | Assessment |
|---|---|
| PAM1 has two netplan files for `ens3`: the installer's (`dhcp4: true`, `dhcp6: true`) and the static one | Netplan merges them; the static file turns DHCPv4 off but `dhcp6: true` survives. No effect today (SEC has no IPv6), but the host does not match "static only". Remove the installer file in 2B |
| `50-cloud-init.conf` on PAM1 says `PasswordAuthentication yes` | Overridden: sshd keeps the first value, and `00-ztna-hardening.conf` is read first. Same as on the other servers |
| `pamops` has unrestricted passwordless sudo | Accepted: it is the account of a recorded, approved privileged session, and the key only works from PAM1. The standing key disappears in Extension Phase 4 (Vault-signed certificates) |
| Warpgate's own logs are kept 7 days in its database | Fine as a local copy; Extension Phase 6 sends them to LOG1 |

## Findings worth keeping

- Warpgate v0.30.0 can log in to targets with **Vault-signed SSH certificates**; the design was
  updated (see [08-extension-design.md](08-extension-design.md)).
- Warpgate shows host keys as full public keys. To compare with the inventory:
  `read -r k; printf '%s\n' "$k" > /tmp/hostkey.pub; ssh-keygen -lf /tmp/hostkey.pub; rm /tmp/hostkey.pub; unset k`.
- On these Ubuntu servers sshd logs as **`sshd-session`**, not `sshd`; this matters for the Wazuh
  decoders (Extension Phase 7).
- Warpgate logs each shell command of a session; Wazuh can use it (Extension Phase 7).
- Admin access recovery: `sudo warpgate --config /etc/warpgate.yaml recover-access` (sets the user's
  web policy to password only).
- Recording directory to back up (Extension Phase 5) and to watch with file integrity monitoring
  (Extension Phase 7): `/var/lib/warpgate/recordings/`.

## Still open after this phase

- The replay shown was of a short session without commands; the replay of a session showing a
  command and its output is captured in Extension Phase 2B with the other targets.
- Remove the old `phase0-export` line on RADIUS1 and LOG1 (the key can no longer be unlocked).
- Temporary exceptions added in this phase, closed in Extension Phase 3: ufw rule 22 from
  `10.10.50.49` on PAM1 and the `ztna-export` key in labadmin's `authorized_keys` on PAM1.
