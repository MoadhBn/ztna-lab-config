# Phase 4: PKI, MFA and remote access with OpenVPN

**Period:** weeks 2–3. **State:** done.

## Goal

A remote employee reaches only what their group needs, after proving three things: the
device (certificate), the knowledge (password) and the possession of a phone (TOTP).

## PKI on FW1

| Certificate | Use |
|---|---|
| CA `ZTNA-Lab-CA` | Signs everything below |
| `fw1-openvpn` (CN `fw1.ztna.lab`, type Server) | OpenVPN server |
| User certificates, CN = username | One per device: sofien, rayen, itadmin |
| `appserver-web` (CN `auth.ztna.lab`, SANs `auth`, `hr`, `fin.ztna.lab`) | nginx on AppServer (Phase 5) |

## Second factor (RADIUS1)

Each user has an individual TOTP secret in an authenticator app (`user@ztna` entries). The
VPN client has one password field, so the user types the password followed by the 6-digit
code. An unlang policy in the `authorize` section splits the field and rejects any request
without a code:

```text
if (&control:TOTP-Secret) {
	if (&User-Password =~ /^(.+)([0-9]{6})$/) {
		update request {
			&TOTP-Password := "%{2}"
			&User-Password := "%{1}"
		}
	}
	else {
		reject
	}
}
```

In `authenticate`, `Auth-Type PAP { pap; totp }`: both modules must succeed.

## OpenVPN server (FW1)

| Setting | Value | Purpose |
|---|---|---|
| Mode / back end | Remote Access (SSL/TLS + User Auth) / RADIUS1 | Certificate and credentials both required |
| Protocol, port, interface | UDP4, 1194, interface `any` (REMOTE and WAN entry points) | |
| tls-auth | Enabled | Packets without the HMAC signature are dropped before TLS; the service is invisible to scanners |
| Peer certificate | CA ZTNA-Lab-CA, server cert fw1-openvpn, client key usage validated | |
| Strict User-CN Matching | Enabled | Credentials work only with the user's own certificate |
| Data ciphers / digest | AES-256-GCM, CHACHA20-POLY1305 / SHA256 | Authenticated encryption |
| Compression | Refused | Avoids compression side channels |
| Tunnel / topology | 10.10.50.0/24, subnet | Addresses assigned by RADIUS |
| Local network (split tunnel) | 172.16.0.0/24 | Only the server network enters the tunnel |
| Inter-client traffic | Disabled | Remote users cannot reach each other |
| DNS | 10.10.50.1, domain `ztna.lab` | Application names resolve inside the tunnel |

The server was created manually, not with the wizard, which adds an "allow all" rule on the
OpenVPN tab.

## From group to firewall rule

RADIUS returns a fixed `Framed-IP-Address` inside the range of the user's group. The
firewall expresses its policy on ranges, so the group becomes a filtering criterion. A
pushed route is not a permission: the OpenVPN tab decides.

| Group | Alias | Range | Permitted |
|---|---|---|---|
| hr | `VPN_HR` | 10.10.50.16/28 | AppServer:443 |
| fin | `VPN_FIN` | 10.10.50.32/28 | AppServer:443 |
| it-admins | `VPN_IT` | 10.10.50.48/28 | AppServer:443; SSH to `INTERNAL_NETS` |

OpenVPN tab: the three `APP_SERVER`:443 rules (logged), `VPN_IT` SSH, DNS from
10.10.50.0/24 to FW1, then the default deny.

## Clients

- Profiles exported with `openvpn-client-export`. REMOTE1 uses host `10.10.40.1`; Windows
  uses "Other" = `192.168.78.20`. Windows trusts the lab CA
  (`certutil -user -addstore Root`).
- A profile contains the user's private key: mode 600.
- REMOTE1: `sudo openvpn --config ~/sofien.ovpn`, then Ctrl+Z and `bg` to keep the tunnel.

## Tests

| Test | Expected | Evidence |
|---|---|---|
| REMOTE1 without VPN to the application | Blocked | Passed during the build, no recorded output |
| sofien with password + code; `tun0` = 10.10.50.17; application through the tunnel | Connected | Passed during the build, no recorded output |
| Password only | AUTH_FAILED | Passed during the build, no recorded output |
| sofien's profile with rayen's credentials | Refused (strict CN) | Passed during the build, no recorded output |
| rayen 10.10.50.33 and app; rayen SSH RADIUS1 blocked; itadmin SSH allowed; anas rejected; accounting | As designed | Reported; listed as evidence still owed |

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| Application unreachable through the VPN | No HTTPS listener on AppServer yet | nginx on 443 (Phase 5) |
| AUTH_FAILED after setting the interface to `any` | Clock drift, then a per-user mismatch | Clocks synchronised; authentication checked with `radtest` |

## Added later

The certificate revocation list was attached on 7 October
([07-hardening-sessions.md](07-hardening-sessions.md)).
