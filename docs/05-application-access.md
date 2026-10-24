# Phase 5: application-level Zero Trust access

**Period:** weeks 3–4. **State:** done.

## Goal

At the network layer, any request reaching AppServer:443 got the application. This phase
places each application behind its own identity-aware proxy and decides every request on
identity, group and location.

## Architecture (AppServer, Docker Compose project `~/ztna`)

```text
nginx :443 (host) ── auth.ztna.lab ──> Keycloak 127.0.0.1:8080 ── PostgreSQL (db-net)
                  ── hr.ztna.lab   ──> hr-proxy 127.0.0.1:4180  ── HR app  (hr-net)
                  ── fin.ztna.lab  ──> fin-proxy 127.0.0.1:4181 ── FIN app (fin-net)
```

| Service | Image | Published | Notes |
|---|---|---|---|
| db | postgres:16-alpine | none | db-net (internal) |
| keycloak | quay.io/keycloak/keycloak:26.3 (26.3.5 running) | 127.0.0.1:8080 | `start`; hostname `https://auth.ztna.lab`; proxy headers `xforwarded`; memory 1 GB; successful logins logged (`KC_SPI_EVENTS_LISTENER_JBOSS_LOGGING_SUCCESS_LEVEL=info`) |
| hr-proxy, fin-proxy | quay.io/oauth2-proxy/oauth2-proxy:v7.6.0 | 127.0.0.1:4180 / 4181 | One instance, client, secret, cookie and allowed group per application |
| hr-app, fin-app | traefik/whoami:v1.10 | none | Shows the identity headers received |

- Only nginx listens on the network; the database and applications have no published port.
- Separate internal networks: the HR proxy can neither resolve nor reach the FIN application.
- Secrets live in `.env` (mode 600): database password, Keycloak admin password, cookie
  secrets, client secrets.
- Logging driver journald with tags `keycloak`, `hr-proxy`, `fin-proxy`.

## Identity provider: Keycloak realm `ztna`

| Setting | Value |
|---|---|
| Self-service | Registration, forgot password and remember-me off |
| Sessions and tokens | SSO idle 30 min, SSO max 8 h, access token 5 min, login action 10 min |
| Brute force | Lockout after 5 failures |
| Events | User and admin events on |
| OTP | TOTP SHA1, 6 digits, 30 s; *Configure OTP* is a default required action |
| Groups | hr, fin, it-admins |
| Users | `user@ztna.lab`, email verified; anas disabled |
| Clients hr-app, fin-app | Confidential, standard flow only, exact redirect `https://<app>.ztna.lab/oauth2/callback`, PKCE S256 |
| Mappers | Group Membership (claim `groups`, full path) and Audience |
| Default scopes | basic, email, profile |

Keycloak administration uses the `master` realm with a named administrator `kcadmin`
protected by OTP; the bootstrap admin was deleted. Phone entries `ztna:user` are separate
from the RADIUS ones (`user@ztna`).

## Proxies (oauth2-proxy)

Provider `keycloak-oidc`; issuer `https://auth.ztna.lab/realms/ztna`; scopes
`openid email profile`; allowed group `/hr` or `/fin`; PKCE S256; cookie refresh 1 min,
expiry 8 h; the lab CA as provider CA; `extra_hosts auth.ztna.lab:172.16.0.10`, so the proxy
reaches Keycloak through nginx over TLS and the issuer URL is identical for the browser and
the back channel.

## Front door and context rules (nginx)

| Server name | Upstream | Access rule |
|---|---|---|
| default (443) | – | `ssl_reject_handshake on`: a bare IP or unknown name gets no certificate |
| auth.ztna.lab | 127.0.0.1:8080 | `/admin` and `/realms/master` only from VPN_IT and IT1 |
| hr.ztna.lab | 127.0.0.1:4180 | HR segment and VPN_HR only |
| fin.ztna.lab | 127.0.0.1:4181 | FIN segment and VPN_FIN only |

nginx decides **where** the request comes from; the proxy and Keycloak decide **who** sends
it. The client address is forwarded in `X-Forwarded-*`, so Keycloak events record the real
source.

## End-to-end chain

A remote HR request passes nine checks in four independent components: interface rule;
tls-auth and CA; certificate CN = username; RADIUS password + TOTP; tunnel range rule;
nginx name and source; valid Keycloak session (else login with password + TOTP); group
claim (else 403); revalidation every minute.

## Tests

| Test | Expected | Evidence |
|---|---|---|
| Bare IP or unknown name | TLS handshake refused | Passed during the build, no recorded output |
| Port scan of AppServer | Only 443 reachable | Passed during the build, no recorded output |
| Unauthenticated request | Redirect to Keycloak | Passed during the build; HTTP 302 reported on 7 October |
| sofien opens HR, then FIN | HR shown; FIN 403 | Passed during the build, no recorded output |
| rayen opens FIN, then HR | FIN shown; HR 403 | Passed during the build, no recorded output |
| IT1 opens HR (wrong place) | 403 by nginx | Passed during the build, no recorded output |
| User disabled or removed from the group during a session | Access ends within about a minute | **Not done** |
| Five wrong passwords | Account locked | **Not done** |

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| `expired_code` at OTP enrolment | The login action code outlived its validity | Login action timeout 10 min |
| Correct TOTP refused (VPN and Keycloak) | Clocks 15 minutes behind; FW1 at stratum 16 | Time design ([06-visibility-and-host-hardening.md](06-visibility-and-host-hardening.md)) |
| `invalid_scope`, shown as 403 | Proxy scopes did not match the client | `openid email profile` |

## Known limits

- Signing out of a proxy does not end the Keycloak SSO session.
- The identity provider runs on the same host as the applications.
