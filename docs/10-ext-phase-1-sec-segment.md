# Extension Phase 1: the SEC segment

**Date:** 8 October 2026. **Commit:** `53619eb`. **State:** done.

## Goal

A new firewalled network, **10.10.60.0/24**, for the security services, starting at
default deny, plus the base host of the future privileged access gateway.

| Host | Address | Arrives in |
|---|---|---|
| PAM1 (Warpgate) | 10.10.60.10 | Built in this phase as the test host; Warpgate in Extension Phase 2 |
| VAULT1 (Vault) | 10.10.60.20 | Extension Phase 4 |
| Wazuh VM | 10.10.60.30 | Extension Phase 7 |

## Why a separate segment

PAM1, Vault and Wazuh are tier-0 assets: whoever controls them controls administration,
secrets or detection. In the IT segment next to IT1, traffic to them would stay on one
switch and pfSense could neither filter nor log it. In their own segment, every flow
crosses FW1. The Wazuh VM needs 4 GB and must run outside EVE, so the segment is also
bridged to a VMware network:

```text
FW1 vtnet6 ── EVE network "SEC" (Cloud2) ── bridge pnet2 on the EVE VM ── eth2 ── VMware VMnet3 ── Wazuh VM (Extension Phase 7)
                     └── PAM1, VAULT1 (EVE nodes)
```

## Step 0: differences between the real configuration and the documents

Reading the exported pfSense configuration before this phase showed four differences,
fixed first:

| Found | Why it mattered | Fix | Evidence |
|---|---|---|---|
| The last rule of the OpenVPN tab was **Reject** | A Reject answers with a reset, so a VPN user scanning can tell closed from filtered; the documents say every tab ends with Block | Changed to Block | **Verified** |
| OpenVPN fallback cipher was `AES-256-CBC` | Last trace of CBC; the cipher list itself was already GCM and ChaCha20 only | Fallback set to `AES-256-GCM` | **Verified** |
| The WAN GUI rule existed twice | Hides what the policy is | Duplicate removed | **Verified** |
| 31 of 42 rules had no description | The firewall log shows the description of the matching rule | Final rules of IT, HR, FIN, REMOTE and DMZ named `Default deny <TAB>` | **Verified** |

## What was done

### VMware and EVE-NG

- **VMnet3** created host-only, **without** a Windows host adapter (Windows must not be on
  SEC) and without VMware DHCP (addresses are static).
- A third adapter on VMnet3 added to the EVE-NG VM; it appears as `eth2`, bridged by `pnet2`.
- FW1 given a 7th interface (added last, so `vtnet0`–`vtnet5` kept their roles).
- An EVE network object **SEC** of type **Cloud2**, connected to FW1 `e6` and PAM1 `e0`.

### pfSense

| Item | Value |
|---|---|
| Interface | OPT5 = `vtnet6`, description `SEC`, static `10.10.60.1/24`, IPv6 none |
| Aliases | `PAM_SERVER` 10.10.60.10, `VAULT_SERVER` 10.10.60.20, `WAZUH_SERVER` 10.10.60.30 |
| DNS overrides | `pam`, `vault`, `wazuh` in `ztna.lab` |
| Outbound NAT | Automatic mode, covers the new network with no change |

**SEC rules:**

| # | Action | Protocol | Source | Destination | Port | Log |
|---|---|---|---|---|---|---|
| 1 | Pass | TCP/UDP | SEC subnets | This Firewall | 53 (DNS) | – |
| 2 | Pass | UDP | SEC subnets | `NTP_SERVER` | 123 | – |
| 3 | Pass | TCP | SEC subnets | **not** `PRIVATE_NETS` | `PORT_WEB` (updates, internet only) | – |
| 4 | Block | any | any | any | any | ✔ |

There is no ICMP rule: unlike the user segments, servers on SEC cannot even ping their
gateway. Rule 3 is inverted so it can never reach another internal segment.

### PAM1 base host

| Item | Value |
|---|---|
| Node | Ubuntu 26.04.1 clone, 512 MB, 1 vCPU, serial console through PuTTY |
| Host name | `pam1` (also in `/etc/hosts`) |
| Identity | New SSH host keys; own machine-id. Fingerprint `kNRjQwjs0rrbqXMktw24haRfQw+CW/6ZcQP20zcuUn4`, machine-id `7e3d566a9ef74530b1a32f8d8c7eb86d` |
| Network | Static `10.10.60.10/24`, gateway and DNS `10.10.60.1`, search `ztna.lab`; cloud-init disabled |
| Time | chrony, single source `192.168.78.10`, `makestep 1 -1`; timesyncd disabled |
| SSH | IT1's key installed, then key-only (`00-ztna-hardening.conf`) |
| Host firewall | ufw: default deny inbound; SSH from IT1 only |

IT1 reaches PAM1 through the existing IT rule `IT_ADMIN → INTERNAL_NETS:22`, which covers
10.10.0.0/16. That rule is removed in Extension Phase 3.

IT1's own identity was recorded at the same time: fingerprint
`fv0UgitcOdPPlpAYqvk5xEgZ5ZKJmEWxi9zRhtmh9DM`, machine-id
`0157b0ba66aa49d38508868a4c044c70`.

## Tests

| Test | Expected | Evidence |
|---|---|---|
| Ping to the gateway 10.10.60.1 | Blocked (no ICMP rule) | Reported |
| `getent hosts auth.ztna.lab`, `vault.ztna.lab` | Resolved through FW1 (rule 1) | Reported |
| `apt-get update` | Works (rule 3) | Reported |
| `chronyc -n sources` | `^* 192.168.78.10` (rule 2) | Reported |
| PAM1 to AppServer:443 and LOG1:22 | Timeout (rule 4) | Reported |
| Block lines for 10.10.60.10 on `vtnet6` reach LOG1 | Present | Reported |
| ARP for 10.10.60.1 seen on `pnet2` | Present | Reported |
| SSH from IT1 with key only | Works, no password | Reported |
| Interface, aliases, overrides, rule order, Step 0 fixes | As designed | **Verified** in the exported `config-redacted.xml` |

The link through VMnet3 itself is proven only when the Wazuh VM joins in Extension Phase 7.

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| The pfSense console started reassigning every interface, with `vtnet6` typed as WAN | The console menu option rebuilds all assignments; it is not the way to add an interface | Cancelled before confirming, so nothing changed. The interface was added in the web GUI (*Interfaces → Assignments*). |
| Name resolution failed on PAM1; `ip neigh` showed `INCOMPLETE` for the gateway | FW1's SEC address had been entered as `10.10.60.11` instead of `10.10.60.1`, so nobody answered ARP for the gateway | Address corrected in *Interfaces → SEC*; the resolver then answered |

## Still open after this phase

- The four SEC rules and the OpenVPN rules have no description.
- PAM1's configuration files are committed in Extension Phase 2, together with Warpgate's.
- The outputs of the PAM1 tests were not recorded; they are captured in Extension Phase 9.
