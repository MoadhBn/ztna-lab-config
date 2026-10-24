# Phase 2: segmentation and default deny

**Period:** weeks 1–2. **State:** done.

## Goal

Replace "trust the inside" with an explicit policy: every flow between segments crosses
FW1, every interface ends with a logged block, and only the flows in a written matrix are
allowed.

## Flow matrix (the written policy)

Every firewall rule derives from this table; anything not listed is denied. Rules are
written for the initiator; replies are accepted by the state table.

| From / To | Internet | FW1 | AppServer | Other internal | Time / logs |
|---|---|---|---|---|---|
| HR, FIN | Web 80/443 | DNS | HTTPS 443 | ✗ | NTP |
| IT1 (admin) | Web 80/443 | DNS, GUI | SSH, HTTPS | SSH 22, ICMP | NTP |
| Other IT hosts | Web 80/443 | DNS | HTTPS 443 | ✗ | NTP |
| REMOTE | Web 80/443 | DNS, VPN 1194 | ✗ | ✗ | NTP |
| VPN users | – | DNS | HTTPS 443 | SSH (IT group only) | – |
| DMZ | Updates 80/443 | DNS | – | ✗ | NTP, syslog to LOG1 |

## Aliases

| Alias | Type | Content |
|---|---|---|
| `ADMIN_PC` | Host | 192.168.78.1 |
| `IT_ADMIN` | Host | 10.10.30.10 (IT1) |
| `APP_SERVER` | Host | 172.16.0.10 |
| `RADIUS_SERVER` | Host | 172.16.0.20 |
| `LOG_SERVER` | Host | 10.10.30.20 |
| `NTP_SERVER` | Host | 192.168.78.10 (EVE-NG chrony) |
| `INTERNAL_NETS` | Network | 10.10.0.0/16, 172.16.0.0/24 |
| `PRIVATE_NETS` | Network | 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 (used inverted = internet only) |
| `PORT_WEB` | Port | 80, 443 |

## Rules per interface

pfSense evaluates rules on the ingress interface, top down, first match wins. Every tab
ends with a logged **Block** (silent drop), not Reject: a Reject answers with a reset or an
ICMP unreachable, which lets a scanner tell closed ports from filtered ones.

| Tab | Allowed flows |
|---|---|
| HR, FIN | DNS to FW1; ICMP to the own gateway; `APP_SERVER`:443 (logged); NTP to `NTP_SERVER`; `PORT_WEB` to `!PRIVATE_NETS` |
| IT | Anti-lockout; DNS; `IT_ADMIN`: ICMP and SSH to `INTERNAL_NETS` (SSH logged); IT subnet to `APP_SERVER`:443; NTP; web. The default "allow LAN to any" rules (IPv4 and IPv6) are disabled, not deleted |
| DMZ | DNS; NTP; web for updates; TCP 514 to `LOG_SERVER` (logging off to avoid a loop). Nothing may be initiated inward |
| REMOTE | UDP 1194 to the REMOTE address (logged, Phase 4); DNS; NTP; web |
| WAN | `ADMIN_PC` to the web GUI (443) and to OpenVPN (1194), logged; bogon networks blocked; "Block private networks" off (the lab's outside is private) |

Two design points:

- **The inverted `PRIVATE_NETS` alias.** "HR to any on 443" would also admit HR to Finance
  on 443; "HR to non-private destinations" admits the internet only.
- **The DMZ never initiates inward.** Even if AppServer, the most exposed host, were
  compromised, it could not open a connection towards users or administrators.

## DNS and NAT

- The pfSense DNS Resolver serves every segment. Host overrides in `ztna.lab` (added in
  Phase 5): `auth`, `hr`, `fin` → 172.16.0.10.
- Outbound NAT is automatic, towards the WAN only. Traffic between internal segments is
  routed without translation, so source addresses are preserved in the logs and usable by
  host firewalls.

## Tests

| Test | Expected | Evidence |
|---|---|---|
| HR1 `curl -k https://172.16.0.10`; ping own gateway; web | Allowed | Passed during the build, no recorded output |
| HR1 ping FIN1; nmap RADIUS1; SSH AppServer; AppServer ping HR1; REMOTE1 ping gateway | Blocked and logged | Passed during the build, no recorded output |
| IT1 SSH to AppServer | Allowed | Passed during the build, no recorded output |

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| Duplicate addresses on servers | The installer's DHCP netplan file was merged with the static one | One netplan file per host |
| `nmap` showed ports "closed" instead of filtered | Final rule set to Reject | Changed to Block |
| `apt` stuck on REMOTE1 | DNS rule placed below the block rule | Rules reordered |
