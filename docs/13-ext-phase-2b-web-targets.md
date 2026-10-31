# Extension Phase 2B, part 2: the pfSense and Keycloak consoles through Warpgate

**Date:** 31 October 2026. **Commit:** the commit that adds this file. **State:** done.
Previous part: [12-ext-phase-2b-targets-approvals.md](12-ext-phase-2b-targets-approvals.md).
With this part, Extension Phase 2 is complete.

## Goal

The two web consoles that administer the lab, the pfSense GUI and the Keycloak admin
console, are reached through Warpgate, each with its own login kept: pfSense with the RADIUS
identity, Keycloak with `kcadmin` and OTP.

```text
itadmin (Keycloak SSO, role ops)
   │
   ├─ https://fw1.pam.ztna.lab ──► Warpgate target fw1-gui ──► https://10.10.60.1 (pfSense GUI)
   │                                                             login: itadmin, RADIUS + code
   └─ https://kcadmin.pam.ztna.lab ► Warpgate target keycloak-admin ► https://auth.ztna.lab (nginx → Keycloak)
                                                                 login: kcadmin + OTP (realm master)
```

## How Warpgate forwards web requests (found by testing)

The Warpgate documentation does not say which host name it passes to an HTTP target. Two
probes answered it before any configuration was written:

| Probe | Observation | Conclusion |
|---|---|---|
| pfSense through Warpgate | No DNS-rebinding error, but *"An HTTP_REFERER was detected other than what is defined in System > Advanced (https://pam.ztna.lab/@warpgate)"* | The `Host` header is the target's (`10.10.60.1`); the `Referer` header is passed unchanged (the browser's) |
| Keycloak through Warpgate | nginx log: `10.10.60.10 host=auth.ztna.lab "GET /admin/" status=403` | `Host` is the target's (`auth.ztna.lab`); the source address is PAM1 |

Everything below follows from these two facts.

## Design decisions

| Decision | Reason |
|---|---|
| Each console on its own Warpgate address (*Bind to a domain*): `fw1.pam.ztna.lab`, `kcadmin.pam.ztna.lab` | Both consoles can be open at the same time, and each address is stable, which Keycloak needs for its links |
| Certificate checking kept on for both targets | A gateway that accepts any certificate could be redirected to an impostor; pfSense received a lab-CA certificate for this |
| No session approval on the web targets | Each console asks for its own second login; Warpgate also refuses HTTP requests outright while an approval is pending |
| pfSense: Warpgate's names added as alternate host names, the HTTP_REFERER check kept on | The check protects the GUI against cross-site request forgery; the names point to PAM1 only |
| Keycloak: the `master` realm's *Frontend URL* set to `https://kcadmin.pam.ztna.lab`; no `KC_HOSTNAME_ADMIN` | Keycloak builds the master login and the admin console addresses from the realm's Frontend URL, so admin logins and the console use the Warpgate address. The `ztna` realm (users, applications, Warpgate's own SSO) keeps `https://auth.ztna.lab` |

## What was done

### FW1 (pfSense)

| Item | Value |
|---|---|
| Certificate `fw1-web` | Lab CA, server certificate, CN `fw1.ztna.lab`, SAN `fw1.ztna.lab`, `10.10.60.1`, `10.10.30.1`, `192.168.78.20`; used by the GUI (replaces the self-signed `GUI default`) |
| Certificate `pam-web-2b` | Lab CA, signed from a CSR made on PAM1; SAN `pam.ztna.lab`, `kcadmin.pam.ztna.lab`, `fw1.pam.ztna.lab`. The 2A certificate `pam-web` was deleted |
| SEC rule | `PAM_SERVER → This Firewall:443`, logged, "PAM1 to FW1 GUI" |
| Admin Access | Alternate host names `pam.ztna.lab fw1.pam.ztna.lab`; HTTP_REFERER check on |
| DNS host overrides | `kcadmin.pam.ztna.lab` and `fw1.pam.ztna.lab` → `10.10.60.10` |

### PAM1

| Item | Value |
|---|---|
| TLS | New key and CSR made on PAM1 (`pam-2b.csr`); the signed certificate installed as `pam.crt` with its key as `pam.key`, so `warpgate.yaml` did not change. The 2A key and certificate were deleted |
| Warpgate target `fw1-gui` | HTTP, `https://10.10.60.1`, TLS required, certificate verified, bound to `fw1.pam.ztna.lab`, role `ops` |
| Warpgate target `keycloak-admin` | HTTP, `https://auth.ztna.lab`, TLS required, certificate verified, bound to `kcadmin.pam.ztna.lab`, role `ops` |

### AppServer

| Item | Value |
|---|---|
| nginx admin rule | `allow 10.10.60.10` added to `/admin` and `/realms/master` (VPN_IT and IT1 still allowed until Extension Phase 3) |
| nginx `X-Forwarded-Host` | Requests from PAM1 are announced to Keycloak as `kcadmin.pam.ztna.lab` (`conf.d/ztna-kcadmin-host.conf`, map on the source address); every other client keeps its own host. Added while `KC_HOSTNAME_ADMIN` was being tried, see below |

### Keycloak

| Item | Value |
|---|---|
| Realm `master` | *Frontend URL* `https://kcadmin.pam.ztna.lab` |
| Realm `ztna` | Unchanged; issuer `https://auth.ztna.lab/realms/ztna` |

## Tests

| # | Test | Expected | Evidence |
|---|---|---|---|
| 1 | Windows browser on `https://192.168.78.20` after the GUI certificate change | No warning | Reported |
| 2 | `curl https://10.10.60.1/` on PAM1 (system trust store) | Certificate accepted | Reported |
| 3 | FW1 log for PAM1 → GUI | Pass line | **Verified**: `vtnet6,match,pass … 10.10.60.10,10.10.60.1,44542,443 … S` (31 October 15:55:34) |
| 4 | `itadmin` logs in to pfSense at `fw1.pam.ztna.lab` | Dashboard, RADIUS identity | **Verified**: pfSense shows `itadmin@10.10.60.10[10.10.50.49] (RADIUS/RADIUS1)`, i.e. the gateway address, the real VPN address passed on by Warpgate, and the RADIUS login |
| 5 | `kcadmin` uses the Keycloak console at `kcadmin.pam.ztna.lab` | Console works | **Verified** (screenshots 15:48–15:49; client links read `https://kcadmin.pam.ztna.lab/realms/master/…`) |
| 6 | Both consoles open at once | Both work | **Verified** (two windows, both carrying Warpgate's injected badge) |
| 7 | Admin console traffic all goes through Warpgate | No direct request to `/admin` or `/realms/master` | **Verified**: on LOG1, the last direct requests from `10.10.50.49` are at 15:32 (the Frontend URL change itself, made in the normal console); none afterwards, while the console was used through Warpgate |
| 8 | `secops` (no `ops` role) | No console reachable | **Verified**: "You don't have access to any targets yet" |
| 9 | Applications and Warpgate SSO after the changes | Unchanged | Reported: HR application and `itadmin`'s Warpgate login work |
| 10 | Temporary recovery client removed | Not in realm `master` | **Verified**: realm `master` lists 7 clients, Keycloak's 6 built-in ones plus `ztna-realm` |

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| pfSense: HTTP_REFERER error through Warpgate | Warpgate passes the browser's `Referer` (`https://pam.ztna.lab/…`) | Warpgate's names added as alternate host names; the check stays on |
| Keycloak: `403` through Warpgate | The nginx admin rule allowed only VPN_IT and IT1 | `allow 10.10.60.10` |
| `KC_HOSTNAME_ADMIN` tried first: `404` on the console | With an admin host name set, Keycloak serves the console only to requests for that name, and Warpgate forwards with `auth.ztna.lab` | nginx announced PAM1's requests as `kcadmin.pam.ztna.lab`; the console then loaded |
| The console showed "Something went wrong": *Framing 'https://auth.ztna.lab/' violates … frame-src 'self'* | The console checks its login state with a hidden page of the `master` realm, still announced under `auth.ztna.lab`; Keycloak's own security policy allows frames from the console's origin only | `master` realm *Frontend URL* set to the Warpgate address. `KC_HOSTNAME_ADMIN` was then left out: the Frontend URL alone moves both login and console, and the admin host name only added the 404 trap |
| `502 Bad Gateway` for about a minute | Keycloak restarting after the compose change | None needed; waited |
| Admin logins locked: the Frontend URL had been saved as `https://kcadmin.pam.ztna.la` (missing `b`) | Typing error; a realm's Frontend URL applies to every login of that realm | Keycloak's documented recovery, needing no login: Keycloak stopped, `kc.sh bootstrap-admin service` created a temporary admin client (secret generated in a shell variable, never displayed), `kcadm.sh` inside the container corrected `attributes.frontendUrl`, logged in again (the first token named the old issuer, hence an expected `401`), then deleted the client |
| A first check of the realm issuers returned nothing | It was sent through nginx from AppServer itself (`127.0.0.1`), which the admin rule refuses | Asked Keycloak directly on `127.0.0.1:8080` |
| An unencrypted full FW1 backup was again saved in `Downloads` | Backup made without the encryption box | Deleted; the encrypted backup of 15:55 was moved to `C:\ztna-backups\` |

### Recovery commands (AppServer, `~/ztna`)

```text
export KC_TMP_SECRET=$(openssl rand -hex 24)
docker compose stop keycloak
docker compose run --rm -e KC_TMP_SECRET keycloak bootstrap-admin service --client-id temp-recovery --client-secret:env=KC_TMP_SECRET
docker compose start keycloak
docker compose exec -e KC_TMP_SECRET keycloak sh -c '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --client temp-recovery --secret "$KC_TMP_SECRET" --config /tmp/kcadm.config'
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh update realms/master -s 'attributes.frontendUrl=https://kcadmin.pam.ztna.lab' --config /tmp/kcadm.config
# then: get clients -q clientId=temp-recovery, delete clients/<id>, rm /tmp/kcadm.config, unset KC_TMP_SECRET
```

## Findings

- **pfSense records both addresses.** With Warpgate in front, pfSense logs the gateway
  (`10.10.60.10`) and the real client in brackets (`10.10.50.49`), so the administrator's
  network location is not lost.
- **pfSense's login protection now sees one address for every administrator.** Repeated failed
  logins through Warpgate would block `10.10.60.10`, i.e. every administrator at once. To
  handle in Extension Phase 3 together with the console break-glass.
- **The nginx `X-Forwarded-Host` map is probably unnecessary in the final design.** It was
  needed only while `KC_HOSTNAME_ADMIN` was set; the master realm's Frontend URL does not
  depend on the host Keycloak receives. It is kept until it is removed and retested in
  Extension Phase 3, when the nginx admin rule is rewritten anyway; its comment still refers
  to `KC_HOSTNAME_ADMIN`.
- **A one-letter mistake in a realm's Frontend URL locks that realm's logins.** The recovery
  above works without any login; a lockout-and-recovery scenario is added to Extension
  Phase 9.
- One FW1 log line reached LOG1 30 seconds late (15:55:34, received 15:56:04), right after an
  FW1 backup; earlier lines arrived within milliseconds. Below rule R6's 60-second threshold;
  watched in Extension Phase 6.

## Still open

- The direct paths stay open until Extension Phase 3: nginx still allows VPN_IT and IT1 on
  the Keycloak admin pages, and the pfSense GUI is still reachable from ADMIN_PC (WAN) and IT1.
- Tests 1, 2 and 9 have no recorded output.
