# Hardening sessions of 7 October 2026

**State:** done. These closed the open fixes of the original plan before the extension.
Attack scenarios were moved to the very end of the project, so they test the final
configuration once.

## Session 1: safety backup, image pinning, Keycloak password policy

| Change | Why | Evidence |
|---|---|---|
| Safety backups: pfSense encrypted XML; root-only tarballs on RADIUS1, LOG1, AppServer; Keycloak database dump (`pg_dump`) | A quick way back before editing identity components | Reported |
| Container images pinned by digest (`image: name:tag@sha256:…`) with `pin-images.sh`, which pins what is running | A tag can be moved to different content; a digest cannot (supply-chain protection, reproducible restore) | **Verified** in `nodes/appserver/home/labadmin/ztna/docker-compose.yml` |
| oauth2-proxy behaviour for unauthenticated users | If they received a 403 sign-in page, rule R5 "wrong group" would fire on ordinary visitors | Both proxies already returned **302** to Keycloak (reported); no change needed |
| Keycloak password policy, realms `ztna` and `master`: minimum 12, maximum 64, not username, not email, not recently used (3) | NIST SP 800-63B: length matters, no composition rules, no forced expiry | Reported |
| Logrotate rule for `/var/log/ztna` identified | Was unknown | **Verified**: `/etc/logrotate.d/ztna` |

## Session 2: unique RADIUS passwords and BlastRADIUS

| Change | Why | Evidence |
|---|---|---|
| Every RADIUS user given an individually generated password, hashed SHA-512-crypt with **100,000 rounds** and a random salt, through `/usr/local/sbin/ztna-radius-passwd` (password read without echo, passed to `mkpasswd` through a pipe, never displayed) | During the build users shared a password; one cracked hash opened every account. More rounds make each guess 20 times more expensive than the default 5,000 | Reported; script in `nodes/radius1/usr/local/sbin/` |
| Client `fw1`: `require_message_authenticator = yes`, `limit_proxy_state = yes` | BlastRADIUS (CVE-2024-3596): an on-path attacker forges an Access-Accept through an MD5 collision; the HMAC Message-Authenticator stops it | **Verified** in `nodes/radius1/etc/freeradius/3.0/clients.conf` |
| FreeRADIUS version 3.2.8 (the settings exist from 3.2.5) | | **Verified** |
| `auth_badpass = no`, `auth_goodpass = no` | Typed passwords never reach the logs | **Verified** |

Finding: a check that counted identical hash strings could not prove unique passwords,
because each `mkpasswd` run uses a new salt. Uniqueness comes from generating each password
separately.

## Session 3: certificate revocation (CRL)

| Change | Evidence |
|---|---|
| CRL `ZTNA-Lab-CRL`, internal, issued by ZTNA-Lab-CA, lifetime 730 days, attached to the OpenVPN server | **Verified** in `nodes/fw1/config-redacted.xml` |
| Throw-away certificate `crltest` (30 days) revoked with reason Key Compromise (serial 9) | **Verified** in the same file |
| Before revocation the test certificate passed TLS and was refused by RADIUS; after revocation it was refused during the TLS handshake, before RADIUS was asked | Reported |

Findings from the running OpenVPN configuration (**verified**):

- pfSense 2.9 deploys the CRL in a `capath` directory (`<hash>.0` CA, `<hash>.r0` CRL), not
  with a `crl-verify` line.
- `inactive 300`: an idle tunnel is closed after 5 minutes.
- No `duplicate-cn`: one active session per certificate.
- OpenVPN runs as root (pfSense default).
- The server still accepted AES-256-CBC; removed from the cipher list here, and from the
  fallback in Extension Phase 1.

Revocation is checked at each new handshake, so an open session survives it. The complete
leaver procedure is: revoke the certificate, disable the user in RADIUS and Keycloak, kill
the active session in *Status → OpenVPN*.

## Session 4: time on every node

| Change | Evidence |
|---|---|
| Every node: chrony with the single source 192.168.78.10, `makestep 1 -1`, `rtcsync`; timesyncd and htpdate absent | Reported |
| NTP rules present on HR, FIN, IT, DMZ and REMOTE tabs | **Verified** in the exported configuration |
| Ubuntu release 26.04.1 LTS | **Verified** |

## Abandoned attempt: SSH second factor through `pam_radius_auth`

A session was written to add RADIUS + TOTP to SSH through Pluggable Authentication
Modules. "PAM" in the project brief meant **Privileged Access Management**, so it was
discarded and never run on any node.
