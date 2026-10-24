# Phase 3: central identity with FreeRADIUS

**Period:** week 2. **State:** done.

## Goal

One place where identities and groups live, and from which a user is revoked: RADIUS1 is
the network-layer policy decision point, FW1 its only client.

## Design

```text
User ──login──> FW1 (RADIUS client / NAS) ──Access-Request, UDP 1812──> RADIUS1 (FreeRADIUS)
                                          <──Access-Accept (Class, Framed-IP) or Access-Reject──
```

Authentication is decided by RADIUS; authorisation is applied by the enforcing device
(pfSense maps the returned `Class` to a local group).

## Configuration (RADIUS1, `/etc/freeradius/3.0/`)

| File | Content |
|---|---|
| `clients.conf` | Client `fw1`: 172.16.0.1 (FW1's DMZ address), 40-hex shared secret, short name `fw1`; plus `localhost` (`testing123`) for local tests |
| `mods-config/files/authorize` | Users at the top of the file (first match wins) |
| `mods-enabled/totp` | Symlink enabling the TOTP module (Phase 4) |
| `sites-available/default` | Password/code split and `Auth-Type PAP { pap; totp }` (Phase 4) |
| `radiusd.conf`, section log | `destination = syslog`, `syslog_facility = local5`, `auth = yes`, `auth_badpass = no`, `auth_goodpass = no` |

User entry format (secrets masked):

```text
sofien  Crypt-Password := "$6$<hash>", TOTP-Secret := "<BASE32>"
        Class := "hr",
        Framed-IP-Address := 10.10.50.17,
        Framed-IP-Netmask := 255.255.255.0

anas    Auth-Type := Reject
        Reply-Message := "Account disabled"
```

| User | Class | Framed-IP (Phase 4) | pfSense privileges |
|---|---|---|---|
| itadmin | it-admins | 10.10.50.49 | WebCfg – All pages |
| sofien, ramez | hr | .17, .18 | none |
| rayen, ranim | fin | .33, .34 | none |
| anas | – | – | rejected (former employee) |

Passwords are salted SHA-512 crypt hashes (`mkpasswd`). PAP is used between FW1 and RADIUS1
because it is the only method compatible with hashed storage; the password is protected in
transit by the shared-secret obfuscation and travels only on the DMZ.

## pfSense integration

- *System → User Manager → Authentication Servers*: RADIUS1, PAP, ports 1812/1813, NAS IP
  attribute = DMZ interface. No firewall rule is needed: traffic from the firewall itself is
  allowed and replies return through the state table.
- Local groups `it-admins` (privilege "WebCfg – All pages"), `hr`, `fin`, scope Remote.
- The GUI authenticates through RADIUS1; the local `admin` account is kept as break-glass.

## Logging

Log lines (program name `radiusd`), as later received on LOG1 (**verified**):

```text
radius1 radiusd[1283] (10) Login OK: [sofien] (from client fw1 port 1194 cli 192.168.78.20:1194)
radius1 radiusd[1283] (11) Login incorrect (pap: Crypt digest does not match "known good" digest): [rayen] (from client localhost port 0)
```

**Finding:** the `cli` field (Calling-Station-Id) holds FW1's own address, not the client's.
RADIUS logs identify the user and the NAS; the source address comes from FW1's OpenVPN lines.

## Tests

| Test | Expected | Evidence |
|---|---|---|
| `radtest itadmin`; pfSense *Diagnostics → Authentication* for itadmin; GUI login itadmin | Accepted, member of it-admins | Passed during the build, no recorded output |
| GUI login sofien; anas; itadmin with a wrong password; revoked itadmin | No rights / rejected | Passed during the build, no recorded output |
| RADIUS log records every attempt without a password | Logged | **Verified** (lines above) |

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| itadmin rejected | Hash generated from a mistyped password | Hash regenerated |
| No group shown in pfSense | No local group matching `Class` | Local groups created with scope Remote |

## Known limits

- FreeRADIUS has no account lockout; repeated rejects are detected by rule R3 (Phase 6).
- During the build several users shared one password; fixed on 7 October
  ([07-hardening-sessions.md](07-hardening-sessions.md)).
