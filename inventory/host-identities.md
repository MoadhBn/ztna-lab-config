# Host identities

SSH host key fingerprints (ED25519) and machine-ids of the lab nodes. These values are
public. They are the reference to compare against on a first SSH connection, and the
values Warpgate must show when it pins a target's host key (Phase 2).

Get them on a node with:

    ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
    cat /etc/machine-id

| Node | Address | Host key (SHA256) | machine-id | Source |
|---|---|---|---|---|
| AppServer | 172.16.0.10 | `3q8re8pgfcEnn4hNU2wqFzoXajY3X/GhyOHvgeQF1H8` | not recorded | shown by scp from Windows, 2026-10-08 |
| RADIUS1 | 172.16.0.20 | `1u207+dI8rKSCY1/mLEhOjg5TE17Y2/RbbvUyK4i2DY` | not recorded | shown by scp from Windows, 2026-10-08; read from PAM1 (`ssh-keyscan`), 2026-10-30 |
| LOG1 | 10.10.30.20 | `WGBLnV2SMkUVag9TEHRqJTKvcL/zifD1/yBFMDXnCss` | not recorded | shown by scp from Windows, 2026-10-08; read from PAM1 (`ssh-keyscan`), 2026-10-30 |
| PAM1 | 10.10.60.10 | `kNRjQwjs0rrbqXMktw24haRfQw+CW/6ZcQP20zcuUn4` | `7e3d566a9ef74530b1a32f8d8c7eb86d` | console output, 2026-10-08 |
| VAULT1 | 10.10.60.20 | `i2DtH3S5vITMrdqF+7raTSUrIQHrFs9bM3NoKL/OOMY` | `92fd22036ff945de8e5e9b892cbb5af7` | console output, 2026-11-01 |
| IT1 | 10.10.30.10 | `fv0UgitcOdPPlpAYqvk5xEgZ5ZKJmEWxi9zRhtmh9DM` | `0157b0ba66aa49d38508868a4c044c70` | console output, 2026-10-08 |
| REMOTE1 | DHCP | not recorded | not recorded | |
| HR1, HR2 | DHCP | not recorded | not recorded | |
| FIN1, FIN2 | DHCP | not recorded | not recorded | |

## Client keys

| Key | Fingerprint (SHA256) | Trusted by | Source |
|---|---|---|---|
| Warpgate on PAM1, `client-ed25519` | `ZyENO54SVtc/gM0crh22i8NtDICSDjCvlFL4SQhw4u0` | `pamops` on AppServer, RADIUS1 and LOG1, `from="10.10.60.10"` only | AppServer sshd log on LOG1, 2026-10-24; exported `authorized_keys`, 2026-10-30 |
| Windows export key `ztna-export` (temporary, Extension Phase 3 removes it) | `P1uwJ06zM1+2YCvfOEy65Ar08mOLjReNEQ8ag346au4` | labadmin on AppServer, PAM1, RADIUS1 and LOG1, `from="10.10.50.49"` only | `ssh-keygen -lf` on Windows, 2026-10-30 |

The five recorded host fingerprints are distinct, and so are the two recorded machine-ids. The
duplicate check on the other nodes was run on 2026-10-08 and reported clean; their values
were not written down.
