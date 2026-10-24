# Phase 1: foundations

**Period:** week 1 (from 22 September 2026). **State:** done.

## Goal

A working lab platform: the emulator, the firewall with one interface per segment, and a
reusable Ubuntu image for every other node.

## Platform

| Item | Value |
|---|---|
| Host | Windows 11 (French locale, AZERTY keyboard), 16 GB RAM, VMware Workstation |
| Emulator | EVE-NG Community VM, 8 GB RAM, 4 vCPU, nested virtualisation |
| EVE-NG network | Adapter 1 on VMware NAT (VMnet8), static `192.168.78.10`, gateway and DNS `192.168.78.2`, bridge `pnet0` (Cloud0). Adapter 2 on VMnet2 (VMware DHCP off), bridge `pnet1` (Cloud1), used as the HR switch |
| Windows on VMnet8 | `192.168.78.1`, alias `ADMIN_PC` |
| Firewall FW1 | pfSense CE 2.9.0 (Netgate Installer), UFS on GPT (BIOS), 6 NICs, 1 GB RAM, `fw1.ztna.lab`, clock source `kvmclock` |
| Ubuntu nodes | Ubuntu Server 26.04.1 LTS, cloned from one flattened image in `/opt/unetlab/addons/qemu/linux-ubuntu-24.04/` (the folder name only selects the EVE-NG template) |

## Nodes

| Node | Segment | Address | RAM | Console | Role |
|---|---|---|---|---|---|
| FW1 | all | see below | 1 GB | serial | Firewall, router, DHCP, DNS, NTP client, OpenVPN, CA |
| HR1, HR2 | HR | DHCP .100–.200 | 512 MB | VNC | HR workstations |
| FIN1, FIN2 | FIN | DHCP .100–.200 | 512 MB | VNC | Finance workstations |
| IT1 | IT | 10.10.30.10 static | 512 MB | VNC | Administrator workstation, SSH key holder |
| LOG1 | IT | 10.10.30.20 static | 512 MB | serial | Log collector (Phase 6) |
| REMOTE1 | REMOTE | DHCP | 512 MB | serial | Remote employee |
| AppServer | DMZ | 172.16.0.10 static | 2 GB | serial | Applications and identity provider |
| RADIUS1 | DMZ | 172.16.0.20 static | 1 GB | serial | FreeRADIUS |

The Windows host plays three roles: administrator (`192.168.78.1`), remote employee
(OpenVPN GUI over the WAN) and HR office PC on VMnet2 (`10.10.10.50/24`, no gateway, DNS
`10.10.10.1`, persistent route `172.16.0.0/24` via `10.10.10.1`).

## Firewall interfaces

| EVE port | NIC | pfSense role | Name | Address |
|---|---|---|---|---|
| e0 | vtnet0 | WAN | WAN | 192.168.78.20/24, gateway .2 |
| e3 | vtnet3 | LAN | IT | 10.10.30.1/24 |
| e1 | vtnet1 | OPT1 | HR | 10.10.10.1/24 |
| e2 | vtnet2 | OPT2 | FIN | 10.10.20.1/24 |
| e4 | vtnet4 | OPT3 | REMOTE | 10.10.40.1/24 |
| e5 | vtnet5 | OPT4 | DMZ | 172.16.0.1/24 |

The pfSense *LAN* role, which carries the anti-lockout rule, is assigned to IT, so the
administration network is IT rather than a business department. Each internal interface
is the gateway and DNS server of its segment. IPv6 is disabled everywhere, so there is no
unfiltered path. DHCP serves the user segments; servers and IT1 use static addresses.

## Golden image

Ubuntu was installed once, then prepared before flattening:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y curl nmap traceroute tcpdump dnsutils netcat-openbsd
sudo touch /etc/cloud/cloud-init.disabled   # no network rewrite at boot
sudo truncate -s 0 /etc/machine-id          # unique DHCP identity per clone
sudo rm -f /etc/ssh/ssh_host_*              # unique SSH host keys per clone
sudo apt clean && sudo poweroff
```

The overlay was flattened with `qemu-img convert` into a standalone `virtioa.qcow2`. Each
clone was then personalised: host name, new SSH host keys
(`sudo dpkg-reconfigure openssh-server`), and for servers and IT1 a single static netplan
file (the installer's DHCP file removed, because netplan merges all its files).

## Console access

The EVE-NG web console cannot send AltGr characters on AZERTY (`[ ] \ | { } # @ ~`).
Servers therefore use a serial console:

1. `/etc/default/grub`: `GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200"`, then `sudo update-grub`.
2. EVE-NG node console type: telnet.
3. PuTTY: Telnet to `192.168.78.10`, port `32768 + node ID`; then `stty rows 40 cols 140`.

Configured on RADIUS1, REMOTE1, AppServer and LOG1. IT1 stays on VNC, so every command
written for IT1 avoids AltGr characters (for example `ssh -l labadmin 172.16.0.10`).

## Problems met and how they were solved

| Problem | Cause | Fix |
|---|---|---|
| `qemu-img commit` crashed ("Co-routine re-entered recursively") | Tool bug | `qemu-img convert` into a new image |
| Addresses changed with the Wi-Fi network | Bridged networking | VMware NAT with static addresses |
| Installer download failed | Large transfer through nested virtualisation | Retry with MTU 1400 |
| "No valid storage devices" | Node created without a disk | `qemu-img create virtioa.qcow2 20G` |
| Serial console silent | GRUB typo (`tty` instead of `ttyS0`) | Whole line rewritten |

## Operating rules that came out of this phase

- Never suspend the EVE-NG VM; shut nodes down cleanly (`sudo poweroff`; pfSense
  *Diagnostics → Halt*) before stopping them in EVE-NG.
- FW1 is never wiped: its installation lives in its overlay.
