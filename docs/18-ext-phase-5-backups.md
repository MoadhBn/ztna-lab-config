# Extension Phase 5: encrypted backups, signed manifests, restore drill

**Date:** designed 3 November, run 4–5 November 2026. **Commit:** the commit that adds this file.
**State:** done. The steps below are the session guide as run, with the results recorded after
each step; the Tests table summarises them. Previous phase: [17-ext-phase-4d-ssh-ca-transit-breakglass.md](17-ext-phase-4d-ssh-ca-transit-breakglass.md).

## Goal

Every server can be rebuilt from this repository plus an encrypted backup, and the drill proves
it with timings. Backups are pulled every night by a job that never holds a standing SSH key,
never sees a plaintext backup and cannot decrypt one. LOG1's finished log files get a daily
manifest signed by Vault, so a later change or deletion is detectable.

```text
                    Vault (VAULT1)  ssh-client-signer/sign/backup   transit/sign/manifest-sign
                        ▲  AppRole "backup-job", from 10.10.30.20 only   (no decrypt rights)
                        │
LOG1  ztna-backup-job ──┤ 5-min certificate, principal ztnabackup
(02:30 nightly)         ▼
   ssh ztnabackup@appserver / radius1 / pam1 / vault1
        └─ forced command: sudo ztna-backup-export ─► archive encrypted ON the server
                                                       with backup-kek's PUBLIC key
   ◄── ciphertext only ──┘
   /var/backups/ztna/<run time>/<node>.bkp  +  signed, chained manifests
        └─► weekly copy to Windows C:\ztna-backups\lab\ (scp through Warpgate, target log1)

Restore: Vault UI, OIDC role "backup-restore" (30 min) ─► transit/decrypt/backup-kek ─► passphrase of ONE archive
```

## Vendor facts checked before the design

| Source | Fact | Used for |
|---|---|---|
| Vault API, *Transit* | Key types include `rsa-4096` and `ed25519`; decrypt takes `padding_scheme` (default `oaep`) and `hash_algorithm` (default `sha2-256`, the hash inside OAEP); `sign` defaults to SHA-256; keys are not exportable unless created so | Key `backup-kek` (RSA-4096): servers encrypt with its public key, only Vault decrypts. Key `manifest-sign` (Ed25519) |
| Vault API, *SSH secrets engine* | `default_critical_options` apply only "if none are provided when signing"; `allowed_critical_options` empty = any option allowed; `allowed_extensions` unset = requester gets `default_extensions` | Role `backup` lists `source-address,force-command` only. Because a requester can still replace the default values, **the servers enforce the same limits themselves** (principals file, below) |
| Vault API, *raft storage* | `GET /sys/storage/raft/snapshot` streams a snapshot; restore with `POST …/snapshot`, `snapshot-force` skips the check that the unseal keys match | Vault backup taken through the API by the job |
| OpenSSH, *sshd_config* | `AuthorizedPrincipalsFile` is used for certificates from `TrustedUserCAKeys`; each line may carry `authorized_keys` options (`from=`, `command=`, `restrict`); default `none` = principal must equal the user name | Server-side `from=` and `command=` for `ztnabackup`, and `from=` for `pamops` |
| OpenSSH, `auth-options.c` behaviour | When a certificate's `force-command` and the principals file's `command=` are both present they must be identical, or the login is refused | The two forced commands are written character for character the same |
| Warpgate | No vendor backup procedure published (search 3 Nov 2026); data in `database_url: sqlite:/var/lib/warpgate/db` | SQLite online backup API (consistent copy while Warpgate runs); path checked on PAM1 in Step 0 |

## Findings from the configuration check (before any change)

| # | Finding | Consequence |
|---|---|---|
| F1 | The roadmap said "pull `ztna-config-export -`". That export is **sanitised**: no keys, no hashes, no TOTP seeds, no Keycloak database, no Warpgate database. Nothing could be restored from it | **Decision reversed:** a second script, `ztna-backup-export`, makes the full backup; `ztna-config-export` stays the Git export |
| F2 | The Transit key `backup` (aes256-gcm96, Phase 4D) only works for a holder of Vault credentials. Envelope encryption with it means the job holds the plaintext data key, so a compromised LOG1 reads every backup | **Decision reversed:** encryption at the source with the public half of a new RSA key `backup-kek`. The servers need no Vault credential; the job never sees plaintext. Key `backup` stays unused (deletion is not allowed on it) |
| F3 | Vault's SSH role defaults can be overridden by the requester (see vendor facts). This is also true of Phase 4D's role `warpgate` | Server-side `from=` for `pamops` and for `ztnabackup` in `/etc/ssh/auth_principals/` |
| F4 | `vault-admin` can write policies, so an administrator could rewrite `vault-admin` itself and remove its own `deny` lines (audit, break-glass, and the new backup ones) | The denies are guard rails, not a boundary. Recorded; every `sys/policies/acl/*` write is in the audit log and becomes a Wazuh rule in Phase 7 |
| F5 | Vault's logical configuration (policies, roles, mounts) is not in this repository | Exported in Step 1 into `nodes/vault1/vault-config/` |
| F6 | LOG1 does not have the lab CA in its trust store; FW1 has no rule from LOG1 to VAULT1 or to port 22 anywhere | Step 2 and Step 3 |
| F7 | `ztna-config-export` fails on a leftover archive owned by another user in `/tmp` | Fixed: the script removes `$out` before writing (root may delete, not overwrite) |

## Design decisions

| Decision | Reason |
|---|---|
| Job on **LOG1**, not on a new VM and not on PAM1 | No RAM for another VM (Wazuh needs 4 GB in Phase 7). PAM1 is the gateway: backups do not belong there. Because archives are encrypted on the servers, LOG1 holds only ciphertext |
| New account `ztnabackup` on every server, not `pamops` | Separate principal, separate certificate role; `pamops` keeps full sudo for humans, `ztnabackup` can run one command |
| Restrictions in three places: the certificate (`source-address`, `force-command`, no extensions), the server's principals file (`from="10.10.30.20"`, same `command=`, `restrict`), sudo (exact command, no arguments) | Any one of them alone is enough; F3 shows why the certificate alone is not |
| New machine path LOG1 → port 22 of AppServer, RADIUS1, PAM1, VAULT1 | It is **not** an administrative path: no shell, no PTY, no forwarding, one fixed command whose output is ciphertext. Stated as an exception to the Phase 3 rule, logged by FW1 and sshd |
| `ztnabackup`'s certificate: 5 minutes, fresh key pair per node per night, deleted after use | No standing key on LOG1 either |
| AppRole `backup-job`: secret-id and token bound to `10.10.30.20/32`, token 15 min; secret-id delivered by **response wrapping** | The credential is useless from another host; the wrapping token is single-use, so seeing it after delivery is harmless and a stolen one makes the real delivery fail visibly |
| Per-archive random passphrase (256 bits), wrapped with RSA-OAEP-SHA256, archive with `openssl enc -aes-256-cbc -pbkdf2` | Decrypting one archive reveals nothing about another. `openssl enc` has no authenticated mode: integrity comes from the signed manifest, checked before decryption |
| Plaintext dumps (Keycloak, Warpgate) only in `/run` (RAM) on the server; the passphrase never in a process argument list | Nothing secret at rest outside the encrypted file |
| Decryption: OIDC role `backup-restore` (group `it-admins`, policy `backup-restore` only, 30 min), chosen explicitly at login; `vault-admin` denied decrypt, export and key config on `backup-kek` | A restore is a deliberate, separately audited act; an ordinary admin session cannot read backups. Not a two-person rule (Vault Community has no control groups): limitation recorded |
| Manifests: SHA-256 of the **uncompressed** content of yesterday's rotated files, signed with Ed25519 key `manifest-sign`, each naming the hash of the previous manifest | Valid after `.1` becomes `.2.gz`; deleting a manifest breaks the chain; each signature is in Vault's audit log on another host |
| Retention: 14 nightly sets on LOG1; manifests kept; weekly copy to Windows | Two copies on two machines; the Windows copy protects against loss of LOG1 |
| FW1: encrypted GUI backup after every change and weekly, passphrase in Vault `secret/backup/fw1-config` | pfSense has no SSH path in this design; the passphrase must be retrievable without the operator's memory |
| Restore drill on **RADIUS1**, onto a new node from the golden image | VPN and pfSense logins depend on it; small; a failed drill is recovered by restarting the original node |

## What each backup contains

Common to every node (`/etc/ztna-backup/paths`): `/etc/ssh` (including the **host keys**, so a
rebuilt node keeps its identity), `/etc/machine-id`, `/etc/hostname`, `/etc/hosts`,
`/etc/netplan`, `/etc/chrony`, `/etc/ufw`, `/etc/sudoers.d`, `/etc/ztna-export.list`,
`/etc/ztna-backup/paths`, `backup-kek.pub`, `backup-kek.version`, `/usr/local/sbin`,
`/home/pamops/.ssh`.

| Node | Added |
|---|---|
| AppServer | `/etc/rsyslog.d`, `/etc/nginx`, `/etc/ssl/ztna`, `/etc/vault-agent/agent.hcl`, `compose.env.ctmpl`, `role-id` (the secret-id is **not** backed up: a restore issues a new one), `/etc/systemd/system/vault-agent.service`, `/home/labadmin/ztna/docker-compose.yml`, `pin-images.sh`; dump `ztna-dumps/keycloak.pgdump` (`pg_dump -Fc`) |
| RADIUS1 | `/etc/rsyslog.d`, `/etc/freeradius` (users with hashes and TOTP seeds, client secrets, certificates) |
| PAM1 | `/etc/warpgate.yaml`, `/etc/warpgate-tls`, `/etc/systemd/system/warpgate.service`, `/var/lib/warpgate/recordings`; dump `ztna-dumps/warpgate.sqlite3`. The binary is not backed up: reinstalled from the signed v0.30.0 release |
| VAULT1 | `/etc/vault.d` (TLS key included), `/etc/systemd/system/vault.service`, `/etc/fstab`, CA. Vault's data comes from the raft snapshot (`vault-raft.bkp`), taken by the job through the API |
| LOG1 | `/etc/rsyslog.d`, `/etc/logrotate.d`, `/etc/systemd/system/ztna-*`, `/usr/local/bin`, `/var/lib/ztna-detect`, `/home/labadmin/lnav`, `/etc/ztna-backup/known_hosts`. Not its AppRole credential. Not the logs themselves: they are covered by the manifests (integrity) and, from Phase 7, by the Wazuh copy |

## Scripts (in `scripts/`)

| Script | Installed | Role |
|---|---|---|
| `ztna-backup-export` | `/usr/local/sbin/`, root 755, on all five servers | Collects, dumps, encrypts to stdout; `--stdin NAME` encrypts standard input (raft snapshot) |
| `ztna-backup-job` | `/usr/local/sbin/` on LOG1 | `nightly` = `logs` + `backup`; `verify-logs FILE`; `probe sign|decrypt` for the negative tests |
| `ztna-config-export` | as before, all servers | F7 fix; reinstall everywhere |

## Session guide

Conventions as in every phase: **[host · session · user]** before each command. Warpgate
sessions are recorded: no secret is displayed in them. "Windows" = PowerShell on the admin PC,
connected to the VPN as `itadmin`. `<repo>` = `C:\Users\moadh\Documents\ztna-lab-config`.

### Step 0. Preconditions and facts (read-only)

Preconditions: VAULT1 unsealed (`vault status` → `Sealed false`); the §6 open items A–C done
(FW1 break-glass test, root-generation ceremony, break-glass user names); a fresh encrypted FW1
backup in `C:\ztna-backups\`.

Run on **each** of `appserver`, `radius1`, `pam1`, `vault1`, `log1` **[Warpgate web session · pamops]**:

```bash
df -h / /run
```
Expect: `/` with several GB free; note `/run`'s free space (it is RAM, about 10 % of it).

```bash
openssl version; python3 --version
```
Expect OpenSSL 3.x and Python 3.x on every node. Stop if either is missing.

**[appserver · Warpgate · pamops]**
```bash
sudo docker exec ztna-db-1 pg_dump -U keycloak -Fc keycloak | wc -c
```
Expect a size in bytes (a few MB). This proves the container name and that local `pg_dump`
works; nothing is written. If "No such container", run `sudo docker ps --format '{{.Names}}'`
and tell me the database container's name: the script must be changed before Step 4.

**[pam1 · Warpgate · pamops]**
```bash
sudo ls -la /var/lib/warpgate /var/lib/warpgate/db
```
```bash
sudo du -sh /var/lib/warpgate/*
```
Record whether `db` is a file or a directory holding `db.sqlite3` (the script handles both),
and the size of `recordings`. **Stop** if the dumps would not fit in `/run` (Keycloak dump +
Warpgate database must be well under `/run`'s free space).

**[log1 · Warpgate · pamops]**
```bash
df -h /var; sudo du -sh /var/log/ztna
```
Budget: 14 sets × (sum of the nodes' backup sizes). Decide retention with this number.

**Step 0 results (3 November, 20:03–20:04):**

| Host | `/` free | `/run` free | OpenSSL / Python | Other |
|---|---|---|---|---|
| PAM1 | 3.7 GB | 90 MB | 3.5.5 / 3.14.4 | `/var/lib/warpgate/db` is a directory: `db.sqlite3` 13 MB plus a 4.3 MB WAL file (the online backup includes WAL content), 17 MB in all; `recordings` 3.2 MB |
| LOG1 | 3.9 GB | 90 MB | 3.5.5 / 3.14.4 | `/var/log/ztna` 18 MB |
| AppServer | 1.7 GB (82 % used) | 327 MB | 3.5.5 / 3.14.4 | Container `ztna-db-1` correct; Keycloak dump 221,785 bytes |
| RADIUS1 | 3.7 GB | 191 MB | 3.5.5 / 3.14.4 | |
| VAULT1 | 2.9 GB | 191 MB | 3.5.5 / 3.14.4 | |

Conclusions: no script change needed; every dump fits in `/run` with a wide margin. A nightly set
is estimated at a few tens of MB, so 14 sets fit easily in LOG1's 3.9 GB: retention stays at 14.
AppServer's disk is the fullest (82 %); nothing is stored there by the backup, but watch it
(Docker images).

### Step 1. Vault (VAULT1)

**[vault1 · Warpgate session · pamops; secops approves]** Copy your token from the Vault UI
(top-right menu → Copy token), then:

```bash
export VAULT_ADDR=https://127.0.0.1:8200
```
```bash
vault login -no-print
```
Paste the token at the hidden prompt. Expect no output (success is silent with `-no-print`).

1.1 Keys. RSA for backups, Ed25519 for manifests. Neither exportable, neither deletable (defaults).
```bash
vault write -f transit/keys/backup-kek type=rsa-4096
```
```bash
vault write -f transit/keys/manifest-sign type=ed25519
```
```bash
vault read -format=json transit/keys/backup-kek | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["keys"]["1"]["public_key"], end="")' > /tmp/backup-kek.pub
```
```bash
openssl pkey -pubin -in /tmp/backup-kek.pub -noout -text | head -n 1
```
Expect `Public-Key: (4096 bit)`. If the Python line fails with `KeyError`, stop and show me
`vault read transit/keys/backup-kek` (it contains no secret).
```bash
openssl pkey -pubin -in /tmp/backup-kek.pub -outform DER | sha256sum
```
Record this value: it is `backup-kek`'s identity, checked on every server.

1.2 SSH role `backup`. No extensions at all = no PTY, no forwarding of any kind.
```bash
vault write ssh-client-signer/roles/backup - <<'EOF'
{"key_type":"ca","allow_user_certificates":true,"allowed_users":"ztnabackup","default_user":"ztnabackup",
 "ttl":"5m","max_ttl":"10m","allowed_extensions":"","default_extensions":{},
 "allowed_critical_options":"source-address,force-command",
 "default_critical_options":{"source-address":"10.10.30.20/32","force-command":"/usr/bin/sudo -n /usr/local/sbin/ztna-backup-export"},
 "key_id_format":"backup:{{role_name}}:{{public_key_hash}}"}
EOF
```
```bash
vault read ssh-client-signer/roles/backup
```
Check: `allowed_users ztnabackup`, both critical options, `default_extensions map[]`, `ttl 5m`.

1.3 Policies.
```bash
vault policy write backup-job - <<'EOF'
# LOG1's nightly job: SSH certificates for ztnabackup, raft snapshot, manifest signatures. No decrypt.
path "ssh-client-signer/sign/backup"  { capabilities = ["update"] }
path "sys/storage/raft/snapshot"      { capabilities = ["read"] }
path "transit/sign/manifest-sign"     { capabilities = ["update"] }
path "transit/verify/manifest-sign"   { capabilities = ["update"] }
EOF
```
```bash
vault policy write backup-restore - <<'EOF'
# Restore only: unwrap the passphrase of a backup, verify manifests.
# Reading the key's description (type, versions, public key; never the private key) is what the
# Vault UI needs before it shows the Decrypt form.
path "transit/keys/backup-kek"        { capabilities = ["read"] }
path "transit/decrypt/backup-kek"     { capabilities = ["update"] }
path "transit/verify/manifest-sign"   { capabilities = ["update"] }
EOF
```
`vault-admin` is extended, not rewritten (keep the current file for rollback):
```bash
vault policy read vault-admin > /tmp/vault-admin.before.hcl
```
```bash
{ cat /tmp/vault-admin.before.hcl; cat <<'EOF'

# Extension Phase 5: administrators cannot read backups or extract the backup key
path "transit/decrypt/backup-kek"      { capabilities = ["deny"] }
path "transit/keys/backup-kek/config"  { capabilities = ["deny"] }
path "transit/export/*"                { capabilities = ["deny"] }
path "transit/backup/*"                { capabilities = ["deny"] }
path "transit/verify/manifest-sign"    { capabilities = ["update"] }
EOF
} | vault policy write vault-admin -
```
Why `transit/keys/backup-kek/config` and `transit/backup/*`: the first could make the key
exportable (irreversible), the second exports the whole key, private half included.

1.4 AppRole for the job.
```bash
vault write auth/approle/role/backup-job token_policies=backup-job secret_id_bound_cidrs=10.10.30.20/32 token_bound_cidrs=10.10.30.20/32 token_ttl=15m token_max_ttl=30m
```
```bash
vault read -field=role_id auth/approle/role/backup-job/role-id
```
The role-id is an identifier, not a secret: record it.

1.5 OIDC role for restores (same Keycloak client and group as `it-admins`, different policy).
```bash
vault write auth/oidc/role/backup-restore - <<'EOF'
{"role_type":"oidc","user_claim":"email","groups_claim":"groups","bound_audiences":["vault"],
 "bound_claims":{"groups":["it-admins"]},
 "allowed_redirect_uris":["https://vault.pam.ztna.lab/ui/vault/auth/oidc/oidc/callback"],
 "oidc_scopes":["openid","email","profile"],"token_policies":["backup-restore"],
 "token_ttl":"30m","token_max_ttl":"30m"}
EOF
```

1.6 FW1 backup passphrase. In the **Vault UI** (`vault.pam.ztna.lab`, as itadmin): Secrets →
`secret/` → Create secret → path `backup/fw1-config`, key `passphrase`, value = the passphrase
you use for pfSense encrypted backups (typed into the masked field). If you do not have one
recorded anywhere, generate one in your password manager and use it from the next backup on.

1.7 ufw on VAULT1 for the job's API calls (SSH from LOG1 comes in Step 4).
```bash
sudo ufw allow proto tcp from 10.10.30.20 to any port 8200 comment 'Vault API from LOG1 (backup job)'
```

1.8 Export Vault's logical configuration (F5). No secret: policies, role definitions, key metadata.
```bash
mkdir -p /tmp/vault-config && for p in $(vault policy list); do vault policy read "$p" > "/tmp/vault-config/policy-$p.hcl"; done
```
```bash
for r in $(vault list -format=json auth/approle/role | python3 -c 'import json,sys; print(*json.load(sys.stdin))'); do vault read -format=json "auth/approle/role/$r" > "/tmp/vault-config/approle-$r.json"; done
```
```bash
for r in it-admins backup-restore; do vault read -format=json "auth/oidc/role/$r" > "/tmp/vault-config/oidc-role-$r.json"; done
```
```bash
for r in warpgate backup; do vault read -format=json "ssh-client-signer/roles/$r" > "/tmp/vault-config/ssh-role-$r.json"; done
```
```bash
vault secrets list -format=json > /tmp/vault-config/mounts.json; vault auth list -format=json > /tmp/vault-config/auth.json
```
```bash
cp /tmp/backup-kek.pub /tmp/vault-config/ && tar -C /tmp -czf /tmp/vault-config.tgz vault-config && grep -rlE 'hvs\.|PRIVATE KEY|"secret_id"' /tmp/vault-config || echo clean
```
Expect `clean`. (The quote before `secret_id` matters: role settings contain `"bind_secret_id": true`, which is not a secret.) **[Windows]**:
```powershell
scp -P 2222 -o User=itadmin:vault1 "pam.ztna.lab:/tmp/vault-config.tgz" C:\Users\moadh\Documents\ztna-lab-config\incoming\
```
Approve in the itadmin browser, secops approves, then press Enter. Then on vault1:
```bash
rm -rf /tmp/vault-config /tmp/vault-config.tgz /tmp/vault-admin.before.hcl
```
Keep `/tmp/backup-kek.pub` until Step 4 is finished on VAULT1; keep the Vault login for Step 3.

**Step 1 results (3 November, 20:20–20:39):**

| Item | Result | Evidence |
|---|---|---|
| `backup-kek` | RSA 4096; DER SHA-256 `abe9afef4ad1f8cb1a440ee953ea5268f035093f07438a0591cf729627166d47` | **Verified** (VAULT1 output; recomputed on Windows from the exported `backup-kek.pub`) |
| `manifest-sign` | Created | Reported |
| SSH role `backup` | `allowed_users ztnabackup`, `allowed_critical_options source-address,force-command`, both defaults set, `default_extensions map[]`, `ttl 5m`, `max_ttl 10m` | **Verified** |
| Policies `backup-job`, `backup-restore`; `vault-admin` extended | As designed; the Phase 5 block of `vault-admin` was appended **twice** (identical, harmless; to be cleaned) | **Verified** in `nodes/vault1/vault-config/` |
| AppRole `backup-job` | Role-id `b375af66-a4e8-775b-9142-afaf97c5e31e`; secret-id and token bound to `10.10.30.20`; token 15 min, max 30 min | **Verified** |
| OIDC role `backup-restore` | Group `it-admins`, policy `backup-restore`, 30 min | **Verified** |
| FW1 passphrase `secret/backup/fw1-config` | Key `passphrase` | Form filled (screenshot before saving); saved version not yet shown |
| VAULT1 ufw | `8200` from `10.10.30.20` added (first typed on LOG1 by mistake, deleted there) | **Verified** on VAULT1 |
| Vault configuration export | 17 files in `nodes/vault1/vault-config/`, scan clean | **Verified** |

Seen in the export, not created by this project: mount `agent-registry/` (type `agent_registry`) and policy
`default-ceiling` (read access to the caller's own registration and to the default policies), both
present by default in Vault 2.x. Also confirmed by the export: the Phase 4D role `warpgate` has
`allowed_critical_options ""` (F3), and `vault-admin` holds `sys/policies/*` with write access (F4).

### Step 2. FW1 (GUI at `fw1.pam.ztna.lab`, itadmin + code)

| # | Where | Setting |
|---|---|---|
| 2.1 | Firewall → Aliases → IP | `BACKUP_SOURCES` = `APP_SERVER`, `RADIUS_SERVER`, `PAM_SERVER`, `VAULT_SERVER`; description "Hosts pulled by the LOG1 backup job" |
| 2.2 | Firewall → Rules → **LAN** (IT), above "Default deny IT" | Pass, TCP, source `LOG_SERVER`, destination `BACKUP_SOURCES` port 22, **log**, "LOG1 backup pull (ztnabackup, forced command)" |
| 2.3 | Same tab, below 2.2 | Pass, TCP, `LOG_SERVER` → `VAULT_SERVER` port 8200, **log**, "LOG1 to Vault (backup job)" |
| 2.4 | Apply; Diagnostics → Backup & Restore | Encrypted backup (passphrase from 1.6) → `C:\ztna-backups\` |

**Step 2 results (3 November, 21:06–21:08):** alias `BACKUP_SOURCES` created; on the LAN tab
"LOG1 backup pull (ztnabackup, forced command)" (`LOG_SERVER → BACKUP_SOURCES:22`) and "LOG1 to
Vault (backup job)" (`LOG_SERVER → VAULT_SERVER:8200`), both logged, directly above "Default deny IT"
(**Verified**, screenshot). Encrypted backup `config-fw1.ztna.lab-20261103210755.xml` in
`C:\ztna-backups\`: header `---- BEGIN config.xml ----`, no `<prv>` (**Verified** on Windows).
Reachability from LOG1 is proven by the Vault health check of Step 3.

Reply traffic is stateful, so no DMZ or SEC rule is needed. Check the 2.4 file on Windows:
first 27 bytes `---- BEGIN config.xml ----`, `<prv>` count 0 (§8 of the handoff).

### Step 3. LOG1: CA, account, credentials, job

**[Windows]** upload the files (log1 needs no approval):
```powershell
cd C:\Users\moadh\Documents\ztna-lab-config
```
```powershell
scp -P 2222 -o User=itadmin:log1 nodes\vault1\usr\local\share\ca-certificates\ztna-lab-ca.crt scripts\ztna-backup-export scripts\ztna-backup-job nodes\vault1\vault-config\backup-kek.pub "pam.ztna.lab:/tmp/"
```

**[log1 · Warpgate · pamops]**
```bash
grep -c $'\r' /tmp/ztna-backup-export /tmp/ztna-backup-job
```
Expect `0` for both (no Windows line endings). Compare `sha256sum /tmp/ztna-backup-*` with
`Get-FileHash scripts\ztna-backup-*` on Windows (case aside, identical).

```bash
sudo install -m 644 /tmp/ztna-lab-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
```
```bash
openssl x509 -in /usr/local/share/ca-certificates/ztna-lab-ca.crt -noout -fingerprint -sha256
```
Expect `B8:46:89:A4:…:1D:E2:64:2B`. **Stop** otherwise.
```bash
curl -sS https://vault.ztna.lab:8200/v1/sys/health
```
Expect JSON with `"sealed":false`. A timeout means rule 2.3 or ufw 1.7; a certificate error means the CA step.

```bash
sudo useradd --system --create-home --home-dir /var/lib/ztnabackup --shell /usr/sbin/nologin --groups adm ztnabackup
```
```bash
sudo install -d -m 750 -o root -g ztnabackup /etc/ztna-backup && sudo install -d -m 755 -o ztnabackup -g ztnabackup /var/backups/ztna /var/backups/ztna/manifests
```
```bash
sudo install -m 755 /tmp/ztna-backup-export /tmp/ztna-backup-job /usr/local/sbin/ && sudo install -m 644 /tmp/backup-kek.pub /etc/ztna-backup/ && echo 1 | sudo tee /etc/ztna-backup/backup-kek.version
```
```bash
sudo openssl pkey -pubin -in /etc/ztna-backup/backup-kek.pub -outform DER | sha256sum
```
Must equal the value recorded in 1.1. `sudo` is needed on LOG1 only: `/etc/ztna-backup` there is
`750 root:ztnabackup` (it holds the AppRole credential), so `pamops` cannot enter it. Without
`sudo`, `sha256sum` hashes empty input and prints `e3b0c442…b855`, the SHA-256 of nothing.

Role-id (from 1.4; not secret):
```bash
echo '<role-id from 1.4>' | sudo tee /etc/ztna-backup/role-id > /dev/null
```

Secret-id by **response wrapping**. Concept: Vault puts the secret-id in a "cubbyhole" and gives
back a wrapping token that can be used **once**, within 5 minutes, to take it out. The real
secret-id is never displayed. If someone else used the wrapping token first, LOG1's unwrap fails
and you know the delivery was intercepted.

**[vault1 · Warpgate · pamops]** (still logged in from Step 1):
```bash
vault write -wrap-ttl=5m -f -field=wrapping_token auth/approle/role/backup-job/secret-id
```
Copy the printed `hvs.…` wrapping token. **[log1 · Warpgate · pamops]**, within 5 minutes:
```bash
read -rsp 'Wrapping token: ' WT; echo
```
```bash
curl -sS --fail-with-body -X POST -H @<(printf 'X-Vault-Token: %s\n' "$WT") https://vault.ztna.lab:8200/v1/sys/wrapping/unwrap | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["secret_id"])' | sudo tee /etc/ztna-backup/secret-id > /dev/null; unset WT
```
Expect no output. `wrapping token is not valid or does not exist` = it was already used or
expired: **stop**, list and destroy the role's secret-ids (`vault list auth/approle/role/backup-job/secret-id`,
then `…/secret-id-accessor/destroy accessor=…`) and repeat.
```bash
sudo chown root:ztnabackup /etc/ztna-backup/role-id /etc/ztna-backup/secret-id && sudo chmod 640 /etc/ztna-backup/role-id /etc/ztna-backup/secret-id
```
```bash
sudo wc -c /etc/ztna-backup/secret-id
```
Expect `37` (36-character UUID + newline). Then on **vault1**: `vault token revoke -self`
(this also logs the Vault UI out: same token).

Sudo rule for LOG1's own backup (`""` = the command may be run with no arguments only):
```bash
echo 'ztnabackup ALL=(root) NOPASSWD: /usr/local/sbin/ztna-backup-export ""' | sudo tee /etc/sudoers.d/91-ztnabackup > /dev/null && sudo chmod 440 /etc/sudoers.d/91-ztnabackup && sudo visudo -cf /etc/sudoers.d/91-ztnabackup
```
Expect `parsed OK`. Paths list:
```bash
sudo tee /etc/ztna-backup/paths > /dev/null <<'EOF'
# ztna-backup-export: what this node's backup contains (LOG1)
/etc/ssh
/etc/machine-id
/etc/hostname
/etc/hosts
/etc/netplan
/etc/chrony
/etc/ufw
/etc/sudoers.d
/etc/rsyslog.d
/etc/logrotate.d
/etc/systemd/system/ztna-detect.service
/etc/systemd/system/ztna-detect.timer
/etc/systemd/system/ztna-digest.service
/etc/systemd/system/ztna-digest.timer
/etc/systemd/system/ztna-backup.service
/etc/systemd/system/ztna-backup.timer
/etc/ztna-export.list
/etc/ztna-backup/paths
/etc/ztna-backup/backup-kek.pub
/etc/ztna-backup/backup-kek.version
/etc/ztna-backup/known_hosts
/usr/local/bin
/usr/local/sbin
/var/lib/ztna-detect
/home/labadmin/lnav
/home/pamops/.ssh
EOF
```
First run, manifests only (no SSH needed yet):
```bash
sudo -u ztnabackup /usr/local/sbin/ztna-backup-job logs
```
Expect `logs manifest <yesterday> signed: N files` (N > 0). An AppRole error shows Vault's message: `CIDR` = wrong source address; `invalid secret id` = Step 3 delivery.

**Step 3 results (4 November, 15:17–15:29):**

| Item | Result | Evidence |
|---|---|---|
| Files in `/etc/ztna-backup/` | `backup-kek.pub`, `backup-kek.version` root 644; `role-id`, `secret-id` `root:ztnabackup` 640 | **Verified** (`ls -l`) |
| Secret-id by response wrapping | Unwrapped on LOG1, never displayed; file 37 bytes; exactly one secret-id on the role (accessor `0170182a-1d8a-6401-412d-7a78cef2b78a`) | **Verified** |
| First signed manifest | `logs manifest 2026-11-03 signed: 157 files`: AppRole login from LOG1, TLS with the lab CA, FW1 rule 2.3, VAULT1's ufw and the `manifest-sign` key all work | **Verified** |
| `backup-kek.pub` fingerprint on LOG1 | `abe9afef…166d47` (the first run without `sudo` hashed empty input, `e3b0c442…`) | **Verified** |
| Manifest content | `ZTNA-LOG-MANIFEST1 host=log1 day=2026-11-03`, `previous none none`, then hash, line count, time, path per file; signature `vault:v1:…` | **Verified** |
| Sudo rule `91-ztnabackup` | `parsed OK` | **Verified** |
| Paths file | Written | Reported |
| Administrator token used for 3.6 | Revoked (`vault token revoke -self`) | **Verified** |

Observations in the first manifest:
- It lists every file currently ending in `.1`, so a file rotated on an earlier day (`alerts.log.1`,
  1 November) is hashed again in each manifest until its next rotation. That is harmless: the hash
  is the same each time.
- It contains `/var/log/ztna/172.16.0.20/_.log` (1 line, 3 November 10:10:41 UTC): a message from
  RADIUS1 that carried no host name and no program name, so rsyslog filed it under the address and
  `_`. Look at that line in Phase 6.

### Step 4. The four servers, one at a time: RADIUS1, AppServer, VAULT1, PAM1

Same procedure on each; **keep the first session open until 4.6 has passed** (it is your way
back if the principals change locks `pamops` out). Approval by secops on each.

4.1 **[Windows]** upload (example RADIUS1; replace the target name):
```powershell
scp -P 2222 -o User=itadmin:radius1 scripts\ztna-backup-export scripts\ztna-config-export nodes\vault1\vault-config\backup-kek.pub "pam.ztna.lab:/tmp/"
```

4.2 **[target · Warpgate session 1 · pamops]** account and files:
```bash
sudo useradd --system --no-create-home --home-dir / --shell /bin/sh ztnabackup
```
The shell must be a real shell: sshd runs the forced command through it. The password stays locked.
```bash
sudo install -d -m 755 /etc/ztna-backup /etc/ssh/auth_principals && sudo install -m 755 /tmp/ztna-backup-export /tmp/ztna-config-export /usr/local/sbin/ && sudo install -m 644 /tmp/backup-kek.pub /etc/ztna-backup/ && echo 1 | sudo tee /etc/ztna-backup/backup-kek.version
```
```bash
openssl pkey -pubin -in /etc/ztna-backup/backup-kek.pub -outform DER | sha256sum
```
Same value as 1.1. Sudo rule:
```bash
echo 'ztnabackup ALL=(root) NOPASSWD: /usr/local/sbin/ztna-backup-export ""' | sudo tee /etc/sudoers.d/91-ztnabackup > /dev/null && sudo chmod 440 /etc/sudoers.d/91-ztnabackup && sudo visudo -cf /etc/sudoers.d/91-ztnabackup
```
Paths list: the common block plus the node's lines from "What each backup contains".
RADIUS1 example:
```bash
sudo tee /etc/ztna-backup/paths > /dev/null <<'EOF'
# ztna-backup-export: what this node's backup contains (RADIUS1)
/etc/ssh
/etc/machine-id
/etc/hostname
/etc/hosts
/etc/netplan
/etc/chrony
/etc/ufw
/etc/sudoers.d
/etc/rsyslog.d
/etc/freeradius
/etc/ztna-export.list
/etc/ztna-backup/paths
/etc/ztna-backup/backup-kek.pub
/etc/ztna-backup/backup-kek.version
/usr/local/sbin
/home/pamops/.ssh
EOF
```
AppServer adds `/etc/nginx`, `/etc/ssl/ztna`, `/etc/vault-agent/agent.hcl`,
`/etc/vault-agent/compose.env.ctmpl`, `/etc/vault-agent/role-id`,
`/etc/systemd/system/vault-agent.service`, `/home/labadmin/ztna/docker-compose.yml`,
`/home/labadmin/ztna/pin-images.sh` (not `/etc/freeradius`). PAM1: `/etc/warpgate.yaml`,
`/etc/warpgate-tls`, `/etc/systemd/system/warpgate.service`, `/var/lib/warpgate/recordings`,
`/usr/local/share/ca-certificates`. VAULT1: `/etc/vault.d`,
`/etc/systemd/system/vault.service`, `/etc/fstab`, `/usr/local/share/ca-certificates`.

4.3 Local test of the export (before any SSH change):
```bash
sudo -u ztnabackup sudo -n /usr/local/sbin/ztna-backup-export | head -n 1
```
Expect `ZTNA-BACKUP1 <node> <time> backup-kek:v1`. (`head` closing early may print
"Broken pipe": harmless.)
```bash
sudo -u ztnabackup sudo -n /usr/local/sbin/ztna-backup-export | wc -c
```
Record the size.
```bash
sudo -u ztnabackup sudo -n /usr/local/sbin/ztna-backup-export /etc/shadow > /dev/null
```
Expect `sudo: a password is required`: with arguments the command no longer matches the `""` rule.

4.4 Principals (F3). Both lines in one go; the `command=` text must equal the certificate's `force-command` exactly.
```bash
echo 'from="10.10.60.10,127.0.0.1" pamops' | sudo tee /etc/ssh/auth_principals/pamops > /dev/null
```
```bash
echo 'from="10.10.30.20",command="/usr/bin/sudo -n /usr/local/sbin/ztna-backup-export",restrict ztnabackup' | sudo tee /etc/ssh/auth_principals/ztnabackup > /dev/null
```
```bash
echo 'AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u' | sudo tee /etc/ssh/sshd_config.d/11-principals.conf > /dev/null
```
```bash
sudo sshd -t && sudo systemctl reload ssh
```
Expect no output from `sshd -t`.

4.5 ufw:
```bash
sudo ufw allow proto tcp from 10.10.30.20 to any port 22 comment 'Backup pull from LOG1 (ztnabackup, forced command)'
```

4.6 **Stop condition.** Open a **second** Warpgate session to the same target. In it:
```bash
sudo grep 'Accepted publickey for pamops' /var/log/auth.log | grep -v 'COMMAND=' | tail -n 2
```
Expect a line from the last minute containing `ED25519-CERT` and `ID warpgate:`. (`grep -v 'COMMAND='` drops sudo's own log entry for this grep, which also contains the searched text and would otherwise be the last match.) Only then
close session 1. If session 2 is refused: in session 1, `sudo rm /etc/ssh/sshd_config.d/11-principals.conf && sudo systemctl reload ssh`, then tell me.

4.7 Reinstalled `ztna-config-export` (F7): add the new files to `/etc/ztna-export.list`:
```bash
printf '%s\n' /etc/ssh/auth_principals /etc/ssh/sshd_config.d/11-principals.conf /etc/sudoers.d/91-ztnabackup /etc/ztna-backup/paths /etc/ztna-backup/backup-kek.pub | sudo tee -a /etc/ztna-export.list > /dev/null
```
On LOG1 also add `/etc/ztna-backup/known_hosts`, `/etc/systemd/system/ztna-backup.service`,
`/etc/systemd/system/ztna-backup.timer`, `/usr/local/sbin/ztna-backup-job` (never `role-id` or `secret-id`).

PAM1 note: its target connects from `127.0.0.1`, covered by the `from=` line. Do PAM1 last.

**Step 4 results, RADIUS1 (4 November, 15:47–16:56):**

| Check | Result | Evidence |
|---|---|---|
| `backup-kek.pub` fingerprint, sudo rule, paths | `abe9afef…166d47`; `parsed OK`; 16 paths | **Verified** |
| Local export as `ztnabackup` | Header `ZTNA-BACKUP1 radius1 2026-11-04T14:47:01Z backup-kek:v1`; 346,478 bytes; with an argument: `sudo: I'm sorry ztnabackup. I'm afraid I can't do that` (refused) | **Verified** (`tar: Broken pipe` after `head` is expected) |
| Principals files and `11-principals.conf` | As designed | **Verified** |
| ufw | `1812:1813/udp` from FW1, `22` from PAM1, `22` from LOG1 | **Verified** |
| Stop condition | sshd reloaded 15:57:51; `pamops` certificate logins from `10.10.60.10` at 15:58:25 and 15:59:40 (`ED25519-CERT`, `ID warpgate:itadmin:…`, CA `HGlS7uRA…`) | **Verified** |
| Pinned host key on LOG1 | `SHA256:1u207+dI8rKSCY1/mLEhOjg5TE17Y2/RbbvUyK4i2DY`, equal to the inventory | **Verified** |
| Pull from LOG1 | Run `2026-11-04T155323Z`: `radius1 OK 346686 bytes`, `vault-raft OK`, `log1 OK`, the three servers not yet prepared time out, `3 OK, 3 failed` | **Verified** |
| RADIUS1's view of the pull | `Accepted publickey for ztnabackup from 10.10.30.20 … ED25519-CERT … ID backup:backup:<key hash> … CA … HGlS7uRA…` (16:48:57 and 16:53:39) | **Verified** (test N6) |
| Export list extended | Done | Reported |

Problems met and fixed on the way:

| Problem | Cause | Fix |
|---|---|---|
| `grep 'Accepted publickey'` returned sudo's own log line | sudo logs the full command, including the searched text, before grep reads the file | `grep -v 'COMMAND='` |
| `find: Failed to restore initial working directory: /home/pamops`, job stopped before its summary | `sudo -u ztnabackup` inherits the caller's directory, which `ztnabackup` may not enter; `set -e` stopped the job | `cd /` at the start of the job |
| A second run on the same day replaced the first run's files and manifest; the chain pointed to a file that had changed | Folder and manifest were named by date only | One folder and manifest per run, named by UTC time; the two test sets of the day deleted |
| `Could not chdir to home directory /home/ztnabackup` on every pull | Account created without a home folder | `usermod --home / ztnabackup` (and `--home-dir /` in 4.2 from now on) |
| `ssh-keygen -lf` and `openssl pkey` on LOG1: `Permission denied` | `/etc/ztna-backup` on LOG1 is `750 root:ztnabackup` | Run with `sudo` |

**Step 4 results, AppServer (5 November, 16:29–16:35):**

| Check | Result | Evidence |
|---|---|---|
| Local export | Header `ZTNA-BACKUP1 appserver 2026-11-05T15:29:16Z backup-kek:v1` (`tar: Child returned status 141` after `head` = SIGPIPE, expected) | **Verified** |
| ufw | `443` from anywhere (nginx), `22` from PAM1, `22` from LOG1 | **Verified** |
| Stop condition | `pamops` certificate login from `10.10.60.10` at 16:33:05, CA `HGlS7uRA…` | **Verified** |
| Pinned host key on LOG1 | `SHA256:3q8re8pgfcEnn4hNU2wqFzoXajY3X/GhyOHvgeQF1H8`, equal to the inventory | **Verified** |
| Pull | Run `2026-11-05T153504Z`: `appserver OK 139296 bytes`, `radius1 OK`, `vault-raft OK`, `log1 OK`, `4 OK, 2 failed` | **Verified** |
| Archive contains the Keycloak dump | Archive 139,296 bytes; the same files without the dump, compressed the same way, 53,098 bytes; the remaining ~86 KB can only be the dump (221,993 bytes raw). In the custom format only table data is compressed, while the schema (Keycloak's many tables) is plain text, so gzip shrinks the dump to about 40 %. Without the dump the archive would be ~54 KB | **Verified** by size; listing in Step 9.1 |
| Fingerprint, sudo rule, principals, containers, AppServer's log line for `ztnabackup`, export list | Done | Reported |

AppServer, completed 5 November: `ztnabackup` login from `10.10.30.20` at 16:35:04 (`ED25519-CERT`,
`ID backup:backup:…`, CA `HGlS7uRA…`) and the six containers `Up` (**Verified**).

**Step 4 results, VAULT1 (5 November, 16:54–17:07):**

| Check | Result | Evidence |
|---|---|---|
| Local export | Header `ZTNA-BACKUP1 vault1 2026-11-05T15:54:41Z backup-kek:v1` | **Verified** |
| Principals files, `11-principals.conf` | As designed; sshd reloaded 17:02:04 | **Verified** |
| ufw | `22` from PAM1, `8200` from PAM1, AppServer, LOG1, `22` from LOG1 | **Verified** |
| Vault after the reload | `Sealed false`, `Version 2.2.1` | **Verified** |
| Export list extended | Five paths appended | **Verified** |
| Pinned host key on LOG1 | `SHA256:i2DtH3S5vITMrdqF+7raTSUrIQHrFs9bM3NoKL/OOMY`, equal to the inventory (closes the VAULT1 part of the host-key item) | **Verified** |
| Pull | Run `2026-11-05T160559Z`: `vault1 OK 43085 bytes`, `5 OK, 1 failed` (PAM1 not prepared); manifest chained to `backup-2026-11-05T153504Z.txt` | **Verified** |
| VAULT1's view | `Accepted publickey for ztnabackup from 10.10.30.20` at 17:06:20, after the reload, `ED25519-CERT`, `ID backup:backup:…` | **Verified** |
| Vault audit | 40 entries on `ssh-client-signer/sign/backup` (request and response per certificate) | **Verified** |
| Stop condition for `pamops` | First checked as `labadmin` on the serial console, where the last `pamops` login shown (16:53:26) predated the reload; then a new Warpgate session: `Accepted publickey for pamops from 10.10.60.10` at 17:12:16 (`ED25519-CERT`, `ID warpgate:itadmin:…`, CA `HGlS7uRA…`), after the 17:02:04 reload | **Verified** |

VAULT1 shows `*** System restart required ***` (pending package updates). A restart seals Vault, which
stops every Warpgate SSH target and the backup job until the unseal ceremony. Plan it as its own step,
with the three unseal keys at hand, not in passing.

**Step 4 results, PAM1 (5 November, 17:37–17:56):**

| Check | Result | Evidence |
|---|---|---|
| Principals files, `11-principals.conf` | As designed; sshd reloaded 17:37:25 | **Verified** |
| Stop condition | `Accepted publickey for pamops from 127.0.0.1` at 17:50:31 (`ED25519-CERT`, `ID warpgate:itadmin:…`, CA `HGlS7uRA…`), after the reload | **Verified** |
| Export list extended | Five paths appended | **Verified** |
| First complete pull | Run `2026-11-05T165503Z`: `appserver OK 137408`, `radius1 OK 346702`, `pam1 OK 4045467`, `vault1 OK 43085`, `vault-raft OK`, `log1 OK`: **6 OK, 0 failed** | **Verified** |
| PAM1's view | `Accepted publickey for ztnabackup from 10.10.30.20` at 17:55:08, `ED25519-CERT`, `ID backup:backup:…` | **Verified** |
| Warpgate during and after the live database copy | `active` | **Verified** |
| Local export tests, ufw | Done | Reported (PAM1's ~4 MB archive in the pull shows the export works) |

The host-key pin line was first run on PAM1 instead of LOG1: it wrote a stray
`/etc/ztna-backup/known_hosts` on PAM1 (holding PAM1's own key, `kNRjQwjs…`, equal to the
inventory), removed afterwards. The successful pull proves LOG1 has a pin for PAM1.

### Step 5. First full run, then the timer

**[log1 · Warpgate · pamops]** pin the host keys the job will accept:
```bash
ssh-keyscan -t ed25519 172.16.0.10 172.16.0.20 10.10.60.10 10.10.60.20 2>/dev/null | sudo tee /etc/ztna-backup/known_hosts > /dev/null
```
```bash
sudo ssh-keygen -lf /etc/ztna-backup/known_hosts
```
**Stop** unless the four fingerprints equal `inventory/host-identities.md` (AppServer `3q8re8pg…`,
RADIUS1 `1u207+dI…`, PAM1 `kNRjQwjs…`, VAULT1 `i2DtH3S5…`). This also closes open item 4
for `pam1` and `vault1`.
```bash
sudo chmod 644 /etc/ztna-backup/known_hosts
```
```bash
sudo -u ztnabackup /usr/local/sbin/ztna-backup-job backup
```
Expect six `backup … OK` lines (appserver, radius1, pam1, vault1, vault-raft, log1) and
`backup set <run time>: 6 OK, 0 failed`. Each run gets its own folder and manifest named by its UTC time (for example `2026-11-04T154929Z`), so a second run on the same day keeps the chain intact.
```bash
run=$(ls -1 /var/backups/ztna | grep "^20" | tail -n 1); ls -l /var/backups/ztna/$run/ && cat /var/backups/ztna/manifests/backup-$run.txt
```
Timer and service:
```bash
sudo tee /etc/systemd/system/ztna-backup.service > /dev/null <<'EOF'
[Unit]
Description=ZTNA nightly backup pull and signed log manifest (Extension Phase 5)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=ztnabackup
Group=ztnabackup
SupplementaryGroups=adm
ExecStart=/usr/local/sbin/ztna-backup-job nightly
# Read-only system except the backup store and /run (the sudo'd self-backup stages there).
# No NoNewPrivileges: LOG1's own backup goes through its single sudo rule.
ProtectSystem=strict
ReadWritePaths=/var/backups/ztna /run /var/lib/ztnabackup
PrivateTmp=yes
EOF
```
```bash
sudo tee /etc/systemd/system/ztna-backup.timer > /dev/null <<'EOF'
[Unit]
Description=Run the ZTNA backup job every night

[Timer]
OnCalendar=*-*-* 02:30:00
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
```
```bash
sudo systemctl daemon-reload && sudo systemctl enable --now ztna-backup.timer && systemctl list-timers ztna-backup.timer
```
Run it once through systemd (proves the sandbox settings):
```bash
sudo systemctl start ztna-backup.service; sudo journalctl -u ztna-backup.service --since "-30 min" --no-pager | tail -n 15
```
Expect `status=0/SUCCESS`. A cold-started lab with Vault sealed makes the job fail: by design.

**Step 5 results (5 November, 17:59–18:08):**

| Check | Result | Evidence |
|---|---|---|
| LOG1's pinned host keys | Four, each equal to the inventory: RADIUS1 `1u207+dI…`, AppServer `3q8re8pg…`, VAULT1 `i2DtH3S5…`, PAM1 `kNRjQwjs…` (closes the host-key item for `pam1` and `vault1` as seen from LOG1) | **Verified** |
| Timer | Next run Fri 6 November 02:32:39 CET (02:30 plus the random delay) | **Verified** |
| Run through systemd (sandbox) | `status=0/SUCCESS`; journal: six `backup … OK`, `backup set 2026-11-05T170611Z: 6 OK, 0 failed`, `Deactivated successfully`, 2.5 s CPU over 11.3 s, 18.5 MB peak memory; sudo logged `ztnabackup … COMMAND=/usr/local/sbin/ztna-backup-export` | **Verified** |
| Stored runs and manifests | Five run folders, one signed manifest per run, log manifests for 3 and 4 November | **Verified** |
| Log manifest of 4 November | `signature: True`, `chain: OK (logs-2026-11-03.txt)`, every file `OK` | **Verified** |
| LOG1's export list | Eight paths added (no `role-id`, no `secret-id`) | **Verified** |
| `ztna-config-export` fix on LOG1, job without duplicate messages | Both installed (hashes `d622ed1b…`, `161544e4…`); a leftover 0-byte `/tmp/ztna-config-log1-2026-11-05.tgz` owned by `pamops` was replaced by the export (19,762 bytes, `-rw-------`): test 13 | **Verified** |

Found in the journal: under systemd every job message appeared twice, once from `logger` and once from
standard output, which the journal also records. Fixed: the job prints to the screen only when run by hand.

### Step 6. Copy off LOG1 (weekly, and right after Step 5)

**[Windows]**:
```powershell
scp -r -P 2222 -o User=itadmin:log1 "pam.ztna.lab:/var/backups/ztna" C:\ztna-backups\lab\
```
These files are ciphertext and signed manifests: safe outside Git, never in the repository.

**Step 6 results (5 November, 18:18):** the whole store copied to `C:\ztna-backups\lab\ztna\` (5 runs,
38 files). On Windows, every `.bkp` of every run matches its signed manifest (`sha256sum -c`), and the
backup manifests form an unbroken chain from `2026-11-04T155323Z` (`3 OK, 3 failed`) to
`2026-11-05T170611Z` (`6 OK, 0 failed`); the log manifests chain from 3 to 4 November. Nothing from
the store appears in `git status`. (**Verified**: owner's `Get-FileHash` against the manifest, and an
independent check of all runs on the copy.)

### Step 7. Manifest tests

**[log1 · Warpgate · pamops]**
```bash
sudo -u ztnabackup /usr/local/sbin/ztna-backup-job verify-logs /var/backups/ztna/manifests/logs-$(date -d yesterday +%F).txt
```
Expect `signature: True`, `chain: OK` (from the second manifest on) and `OK` for every file.

Tamper test (on a copy, restored afterwards):
```bash
sudo cp -a /var/log/ztna/all.log.1 /root/all.log.1.orig && echo 'forged line' | sudo tee -a /var/log/ztna/all.log.1 > /dev/null
```
```bash
sudo -u ztnabackup /usr/local/sbin/ztna-backup-job verify-logs /var/backups/ztna/manifests/logs-$(date -d yesterday +%F).txt | grep -v '^OK'
```
Expect `ALTERED OR MISSING  /var/log/ztna/all.log …`.
```bash
sudo cp -a /root/all.log.1.orig /var/log/ztna/all.log.1 && sudo rm /root/all.log.1.orig
```
Run the verification again: all `OK`. Signature check outside LOG1: Vault UI → `transit` →
`manifest-sign` → Verify, with the Windows copy of a manifest (base64) and its `.sig`.

**Step 7 results (5 November, 18:20–18:35):**

| Test | Result | Evidence |
|---|---|---|
| Forged line appended to `all.log.1` | `signature: True`, `chain: OK`, then `ALTERED OR MISSING  /var/log/ztna/all.log (9946 lines, 2026-11-05T15:20:36Z)` | **Verified** (test 10) |
| Original restored (`cp -a`) | Clean again | **Verified** |
| Manifest of 3 November moved away | `chain: BROKEN (logs-2026-11-03.txt)`; back in place (owner `ztnabackup`, 644): `chain: OK` | **Verified** (test 11) |
| Signatures checked on the Windows copy, without LOG1 and without Vault | All seven manifests (`logs-2026-11-03`, `logs-2026-11-04`, five backup runs): `Signature Verified Successfully` | **Verified** |
| Counter-tests | `logs-2026-11-04` with one word changed, and `logs-2026-11-03` with the 4 November signature: `Signature Verification Failure` | **Verified** |

The Vault 2.2.1 UI cannot do this check: its Transit **Verify** form only offers an HMAC field, so a
signature pasted there is checked as an HMAC and is always reported invalid. Instead, the public
half of `manifest-sign` was exported once (`vault read transit/keys/manifest-sign`, raw 32-byte key)
and stored as `nodes/vault1/vault-config/manifest-sign.pub.pem` (DER SHA-256
`728a565273b3aa36da8b2fada46d5b143d35e37c1da0f2d015e4a109fbec002a`). A manifest is then checked with
OpenSSL alone, which keeps working with LOG1 compromised and Vault sealed:

```bash
# Git Bash on Windows, in C:\ztna-backups\lab\ztna\manifests
sed 's/^vault:v1://' logs-2026-11-04.txt.sig | base64 -d > /tmp/s.bin
openssl pkeyutl -verify -pubin -inkey <repo>/nodes/vault1/vault-config/manifest-sign.pub.pem -rawin -in logs-2026-11-04.txt -sigfile /tmp/s.bin
```

Ed25519 signs the input bytes directly, so the manifest file is verified as it is (Vault's
`hash_algorithm` does not apply). The `v1` prefix names the key version: after a rotation of
`manifest-sign`, the new version's public key must be exported as well.

### Step 8. Negative tests

| # | Where | Command | Expected |
|---|---|---|---|
| N1 | log1 | `sudo -u ztnabackup /usr/local/sbin/ztna-backup-job probe sign pamops` | Vault refuses: `pamops` not a valid principal |
| N2 | log1 | `sudo -u ztnabackup /usr/local/sbin/ztna-backup-job probe decrypt /var/backups/ztna/<latest run>/radius1.bkp` | `permission denied` |
| N3 | Vault UI as itadmin (default role) | `transit` → `backup-kek` → Decrypt, line 2 of a `.bkp` | `permission denied` |
| N4 | Vault UI as itadmin | `backup-kek` → key configuration → Exportable | Refused |
| N5 | vault1 | `vault write -f -field=secret_id auth/approle/role/backup-job/secret-id \| …` login from VAULT1 (as 4C T5), then destroy that secret-id | `source address … unauthorized by CIDR` |
| N6 | radius1 | `sudo grep 'Accepted publickey for ztnabackup' /var/log/auth.log \| grep -v 'COMMAND=' \| tail -n 3` after a run | `Accepted publickey for ztnabackup from 10.10.30.20 … ED25519-CERT ID backup:…` |
| N7 | log1 | `sudo -u ztnabackup /usr/local/sbin/ztna-backup-job probe sign ztnabackup` (prints the certificate, then deletes it) | `Valid: … 5m`, `Principals: ztnabackup`, `Critical Options: force-command /usr/bin/sudo -n /usr/local/sbin/ztna-backup-export`, `source-address 10.10.30.20/32`, `Extensions: (none)` |
| N8 | Windows | `ssh -p 2222 itadmin:radius1@pam.ztna.lab` still works | Warpgate unaffected by the principals file |

**Step 8 results (5 November, 18:34–18:38):** N4 (making `backup-kek` exportable) was replaced by
`vault token capabilities`, which reports the policy decision without acting: a real attempt would be
irreversible if the deny failed.

| # | Result | Evidence |
|---|---|---|
| N1 | `probe sign pamops`: `400`, `pamops is not a valid value for valid_principals` | **Verified** |
| N7 | `probe sign ztnabackup`: valid 18:34:12–18:39:42 (5 min 30 s, including the 30 s back-dating), principal `ztnabackup`, `force-command /usr/bin/sudo -n /usr/local/sbin/ztna-backup-export`, `source-address 10.10.30.20/32`, `Extensions: (none)`, CA `HGlS7uRA…`, key ID `backup:backup:<key hash>` | **Verified** |
| N2 | `probe decrypt` of `radius1.bkp` with the job's token: `403 permission denied` | **Verified** |
| N3, N4 | Administrator token (`vault-admin`): `deny` on `transit/decrypt/backup-kek`, `transit/keys/backup-kek/config`, `transit/export/encryption-key/backup-kek`, `transit/backup/backup-kek`; controls `transit/encrypt/backup-kek` (full rights from `transit/*`) and `transit/verify/manifest-sign` (`update`) | **Verified** |
| N5 | A valid test secret-id used from VAULT1: `400 source address "127.0.0.1" unauthorized by CIDR restrictions on the role`; test secret-id destroyed, only `0170182a…` left | **Verified** |
| N6 | `ztnabackup` logins on the four servers come from `10.10.30.20` with a Vault certificate | **Verified** (Step 4) |
| N8 | Warpgate session to `log1` after all changes | **Verified** |

Notes:
- `transit/verify/manifest-sign` shows only `update`, not the full rights of `transit/*`: in a Vault policy
  the most specific matching path wins, rules are not added together. The same rule makes the four
  `deny` lines win over `transit/*`.
- `probe sign` printed `p-cert.pub:2: invalid key: invalid format` after the certificate: Vault ends
  `signed_key` with a newline and the script added another, leaving a blank second line. `ssh` ignores
  it (every pull worked); the script now strips the newline.

**Correction made in Step 9 (5 November):** the first version of `backup-restore` had no `read` on
`transit/keys/backup-kek`. The restore login worked, but the Vault UI answered `403 Not authorized`
on `/v1/transit/keys/backup-kek`, because it reads the key's description before showing the Decrypt
form. The policy above includes that read; it exposes only metadata and the public key. The policy
grants no `list`, so the Transit key list itself stays `403` for this role; open the key directly at
`https://vault.pam.ztna.lab/ui/vault/secrets-engines/transit/show/backup-kek` (Vault 2.2.1 UI path),
then Key actions → Decrypt. (**Verified**, 5 November.)

### Step 9. Restore tests

9.1 **Decryption from the Windows copy** (non-destructive, every archive). Vault UI: log out,
log in with method OIDC and **role `backup-restore`**. Then for one archive:

**[Windows · Git Bash]** (OpenSSL is included in Git for Windows):
```bash
cd /c/ztna-backups/lab/ztna/<run time>
```
```bash
sed -n 2p radius1.bkp
```
Paste that `vault:v1:…` text into Vault UI → `transit` → `backup-kek` → Decrypt. The result is
base64. **Do not decode it on screen**; copy it, then:
```bash
read -rsp 'Decrypted (base64): ' B; echo; export ZTNA_PASS=$(printf '%s' "$B" | base64 -d); unset B
```
```bash
tail -n +3 radius1.bkp | openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass env:ZTNA_PASS | tar -tzvf - | head -n 20; unset ZTNA_PASS
```
`tail -n +3` skips the two header lines (binary-safe). Expect a listing starting with
`etc/ssh/…`. Listing only: the content is secret and is not extracted on Windows. Repeat for
each archive; for `appserver` look for `ztna-dumps/keycloak.pgdump`, for `pam1`
`ztna-dumps/warpgate.sqlite3`. Each archive needs its own decryption: one passphrase opens one file.

9.2 **Vault snapshot readable.** Upload `vault-raft.bkp` to vault1 (scp through Warpgate,
approval), decrypt as in 9.1 into `/tmp/raft.snap` (no `tar`), then:
```bash
vault operator raft snapshot inspect /tmp/raft.snap | head
```
Then `shred -u /tmp/raft.snap`. If `inspect` is unknown in this version, record its size and the
first bytes instead (`head -c 2 /tmp/raft.snap | xxd` → `1f8b`, gzip). An actual Vault restore
is not done on the only Vault: it would roll back every change since the snapshot.

**Steps 9.1–9.2 results (5 November, 19:03–19:16)**, run `2026-11-05T170611Z`, decrypted on Windows
from the copy, one `backup-restore` unwrap per archive, contents only listed:

| Archive | Checked | Evidence |
|---|---|---|
| `radius1.bkp` | `authorize` (users, hashes, TOTP seeds) and `ssh_host_ed25519_key` both present | **Verified** (`2`) |
| `appserver.bkp` | `ztna-dumps/keycloak.pgdump` 220,922 bytes; `etc/ssl/ztna/appserver.key`; `etc/vault-agent/role-id`, no `secret-id` | **Verified** |
| `pam1.bkp` | `ztna-dumps/warpgate.sqlite3` 15,282,176 bytes (database and WAL merged by the online backup: 13 MB + 4.3 MB before); 533 entries for `warpgate.yaml`, `pam.key`, `recordings/` | **Verified** |
| `vault1.bkp` | `etc/vault.d/vault.hcl`, `tls/vault.key`; no `var/lib/vault` | **Verified** |
| `log1.bkp` | `var/lib/ztna-detect/` (`offset`, `lastseen`, `kc-users`), `etc/ztna-backup/` without `role-id`/`secret-id`, both units | **Verified** |
| `vault-raft.bkp` | `meta.json`, `state.bin` (73,363 bytes), `SHA256SUMS`, `SHA256SUMS.sealed` | **Verified** |
| Audit | 14 entries on `transit/decrypt/backup-kek` = 6 decryptions × 2 + the refused job probe of Step 8 | **Verified** |

Notes:
- `SHA256SUMS.sealed` is Vault's checksum file encrypted with its own barrier key: a snapshot can
  only be restored into a Vault unsealed with the same keys (`snapshot-force` skips that check).
- `etc/vault.d/vault.hcl.bak-4d` is in VAULT1's backup: a copy left in `/etc/vault.d` during Phase 4D.
  The Git export drops `*.bak*`, so it was never reviewed; compare and delete it.
- The optional "wrong passphrase" test was not run (the passphrase had already been unset).
- In the CLI, the first `vault policy write` failed with `403` because `~/.vault-token` on VAULT1
  held the `backup-restore` token (`vault token lookup` showed `['backup-restore', 'default']`);
  it succeeded with an administrator token.

9.3 **Restore drill: RADIUS1 rebuilt on a new node.** Write down the time at each line.

| T | Where | Action |
|---|---|---|
| T0 | — | Start. Backup run chosen and verified against its signed manifest (Step 6) |
| T1 | radius1 · Warpgate | Clean `poweroff` of the original RADIUS1 (its disk is the rollback) |
| T2 | EVE | New node `RADIUS1R` from the golden image, 1 GB, DMZ link, started |
| T3 | RADIUS1R serial · labadmin | Host name, static netplan from the repository, `apt install freeradius freeradius-utils chrony`, accounts `pamops` and `ztnabackup` |
| T4 | Windows → RADIUS1R serial | **Identity first:** RADIUS1's original ED25519 host key taken from the backup (one `backup-restore` unwrap, clipboard only) and placed on the new node; fingerprint must be `1u207+dI…`. Warpgate's and LOG1's pins then match without any change |
| T5 | RADIUS1R serial | Minimal trust for Warpgate from the repository: Vault SSH CA, sshd drop-ins, principals, `90-pamops`; ufw `22` from PAM1 |
| T6 | Windows | First Warpgate session to `radius1`: no host-key warning, `pamops` certificate login |
| T7 | Windows → RADIUS1R | `radius1.bkp` uploaded through Warpgate (`scp`, approval) |
| T8 | RADIUS1R · Warpgate · pamops | Second unwrap; archive decrypted in a pipe and extracted to `/`; `.bkp` deleted |
| T9 | same | `freeradius -XC`, `sshd -t`, `visudo -c`; reboot |
| T10 | same | Identity (host key, machine-id), services, ufw, time, logs reaching LOG1 |
| T11 | FW1 GUI | Diagnostics → Authentication against RADIUS1 → authenticated |
| T12 | Windows | New VPN connection (certificate + password + TOTP) |
| T13 | log1 | Backup job: `radius1 OK` from the rebuilt node, `6 OK, 0 failed` |

**Drill results (5 November, 20:25–20:59).** Backup run `2026-11-05T192455Z` (`6 OK`), RADIUS1's
archive hash `ed710a70…fb573ad9` identical in the manifest, on Windows and on the new node.

| T | Result | Evidence |
|---|---|---|
| T0 | Fresh backup set, `radius1.bkp` hash checked on Windows | **Verified** |
| T2 | Node `RADIUS1R` created; serial console unusable until configured through VNC (finding D1) | **Verified** |
| T3 | Host name, static netplan (`ens3 172.16.0.20/24`) | **Verified** |
| T4 | Host public key from the backup `1u207+dI…`; private key pasted, recomputed public key `1u207+dI…` | **Verified** |
| T5 | Vault SSH CA `HGlS7uRA…`, `90-pamops` parsed, sshd active, ufw `22` from PAM1 | **Verified** |
| T6 | First Warpgate session: no host-key warning; `pamops` certificate login from `10.10.60.10` at 20:47:00 | **Verified** |
| T7 | Uploaded archive hash = manifest hash | **Verified** |
| T8 | 421 entries; extracted to `/`; archive deleted | **Verified** |
| T9 | `freeradius -XC`: `Configuration appears to be OK`; `sshd -t`, `visudo -c` OK; reboot | **Verified** |
| T10 | `radius1`, machine-id `edbc61b5d62046f7a3bb994950b840b3` (from the backup; first time recorded), host key `1u207+dI…`, freeradius/ssh/chrony/rsyslog/ufw active, the three original ufw rules, FreeRADIUS on 1812/1813; chrony reference `192.168.78.10`, 0.00002 s off; on LOG1 `radiusd[1119] … Login OK: [itadmin] (from client fw1 port 1194 …)` at 20:57:36 (PID of the rebuilt node's FreeRADIUS), so the restored forwarding to LOG1 works | **Verified** |
| T11 | FW1 Diagnostics → Authentication against RADIUS1: `User itadmin authenticated successfully`, group `it-admins` | **Verified** |
| T12 | New OpenVPN connection as itadmin at 20:57 (`10.10.50.49`) | **Verified** |
| T13 | Backup job run `2026-11-05T195854Z`: `radius1 OK 346686 bytes` from the rebuilt node with LOG1's existing pin, `6 OK, 0 failed` | **Verified** |

Timing. T1 was not photographed; it is reconstructed from LOG1, where RADIUS1's lines stop at
**20:29:35** (shutdown messages of the original node) and resume at **20:53:26** (boot of the rebuilt
node with its restored rsyslog configuration).

| Moment | Time |
|---|---|
| T1, original RADIUS1 off | 20:29:35 |
| New node on its address (T3) | about 20:36 |
| Identity restored (T4) | about 20:44 |
| First Warpgate session (T6) | 20:47:00 |
| Restore done, reboot (T9) | about 20:52 |
| RADIUS authentication proven from FW1 (T11) | about 20:56 |
| New VPN login proven on LOG1 (T12) | 20:57:36 |
| **Downtime of the RADIUS service** | **about 27 minutes** (20:29:35 → 20:56), including the serial-console detour of D1 |

Drill findings (steps not covered by the repository or the backup):

| # | Finding | Fix |
|---|---|---|
| D1 | The golden image has no serial console; a clone needs one VNC session (`GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200"`, `update-grub`, reboot) before it can be administered without AltGr | Put the GRUB line into the golden image |
| D2 | Packages are not in the backup: `freeradius freeradius-utils chrony` installed from the Ubuntu archive (current versions); the restored configuration was accepted by the installed FreeRADIUS | Record the package list per node in the repository |
| D3 | Accounts are not in the backup (`/etc/passwd` is node-specific): `pamops` and `ztnabackup` recreated by name before the restore | Documented in the drill |
| D4 | RADIUS1 logs to syslog (`destination = syslog` in `radiusd.conf`), not to `/var/log/freeradius/radius.log`; that file only held the default instance started by the package install | Authentication results are read on LOG1 |

Why RADIUS1 and why a new node: a restore onto the running server would have hidden D1–D3 (the old
node already had the serial console, the packages and the accounts). RADIUS1 carries the VPN and
pfSense administrator logins, holds only configuration, is easy to test from FW1 and OpenVPN, and the
untouched original stayed available as the way back. AppServer (Keycloak database), VAULT1 (a
snapshot restore rolls back every later change) and PAM1 or LOG1 (the administrative path and the
backup job themselves) carry more risk for the same proof.

Limit of the drill: one server was rebuilt. The Keycloak database import, the Warpgate database
restore and a Vault snapshot restore were not exercised; 9.1–9.2 only show that the archives contain
them. The next drill would be the Keycloak dump loaded into a throwaway PostgreSQL container.

Design change before the drill: the first outline accepted a temporary host key in Warpgate and
re-pinned it after the restore. Restoring the host key **first** avoids ever telling the gateway to
trust an unknown key, and keeps LOG1's pin valid; the price is one host private key passing through
the Windows clipboard and the serial console (logging off), the same handling as other break-glass
secrets.

Result to record: total time T0→T12, and every step that needed something not in the repository
or the backup (that list is the real finding of a drill). Then either keep RADIUS1R (delete the
old node) or shut it down and restart the original.

### Step 10. Exports and records

Usual end of phase (handoff §8): exports of all five servers through Warpgate (now with
`rm -f` built in), FW1 redacted copy, review, secret scan, `nodes\vault1\vault-config\` from
Step 1.8, `inventory\host-identities.md` (backup-kek fingerprint, `pam1`/`vault1` pinned keys,
RADIUS1 machine-id), this file's Tests table, `STATUS.md`, `docs\README.md`,
`docs\08-extension-design.md`, `docs\links.md`; stage; you commit.

## Tests

| # | Test | Expected | Evidence |
|---|---|---|---|
| 1 | `backup-kek` public key on LOG1 and the four servers | Same DER SHA-256 as on VAULT1 | **Verified** (`abe9afef…` on LOG1, RADIUS1, AppServer, VAULT1; PAM1 by its working encrypted backup) |
| 2 | Secret-id delivery by response wrapping | Unwrap succeeds once; 37-byte file | **Verified** |
| 3 | Signed log manifest | `signature: True`, files `OK` | **Verified** (3 and 4 November) |
| 4 | Local export as `ztnabackup` on each server | `ZTNA-BACKUP1 <node>` header; arguments refused | **Verified** on RADIUS1, AppServer, VAULT1; PAM1 shown by the pull |
| 5 | `pamops` after the principals change, each server | `ED25519-CERT` login after the reload | **Verified** on all four (PAM1 from `127.0.0.1`) |
| 6 | Pinned host keys on LOG1 | Equal to the inventory | **Verified** (closes the host-key item for `pam1` and `vault1`) |
| 7 | First complete backup set | 6 OK, signed manifest | **Verified** (run `2026-11-05T165503Z`) |
| 8 | Run through systemd | `status=0/SUCCESS` | **Verified** (run `2026-11-05T170611Z`) |
| 9 | Copy to Windows | Every file matches its signed manifest | **Verified** (5 runs, chains intact) |
| 10 | Tampered log line | `ALTERED OR MISSING`, then `OK` after restoring | **Verified** |
| 11 | Chain | `chain: OK`; `BROKEN` when a manifest is removed | **Verified** |
| 11b | Signatures checked off LOG1 and without Vault | `Signature Verified Successfully`; counter-tests fail | **Verified** (7/7; 2 counter-tests) |
| N1–N8 | Negative tests (Step 8) | As in the table | **Verified** |
| R1 | Every archive decrypts and lists | Listing as described | **Verified** (6/6) |
| R2 | Raft snapshot readable | Snapshot archive listed | **Verified** (`meta.json`, `state.bin`, `SHA256SUMS`, `SHA256SUMS.sealed`); not restored into Vault |
| R3 | RADIUS1 drill | Logins work; identity preserved; time recorded | **Verified** (about 27 minutes of RADIUS downtime) |
| 12 | FW1 passphrase in Vault, encrypted FW1 backup | KV version 1; file in `C:\ztna-backups\` | **Verified**: passphrase version 1 (3 November); `config-fw1.ztna.lab-20261103210755.xml`, made right after the Phase 5 rules, encrypted (no `<prv>`); FW1 unchanged since (redacted copy of 5 November) |
| 13 | `ztna-config-export` with a foreign leftover in `/tmp` | Archive produced | **Verified** on LOG1 |

## End of phase (5 November, 21:05–21:23)

| Item | Result |
|---|---|
| `vault-admin` | Contains the Phase 5 block once (the duplicate from Step 1 had already been removed); `transit/decrypt/backup-kek` still `deny` |
| `/etc/vault.d/vault.hcl.bak-4d` | Differed from `vault.hcl` only by the `enable_unauthenticated_access` line; deleted |
| LOG1 job script | Final version installed (`6c620057…`), identical to `scripts/ztna-backup-job` |
| Exports | Five servers and the Vault configuration through Warpgate; no private key, no `.env`, no `role-id`/`secret-id`, `client_secret` redacted; secret scan clean. The only differences from the previous exports are the Phase 5 files and ufw rules. The rebuilt RADIUS1's export is identical to the original's apart from them, owners and modes included |
| Vault configuration | `policy-backup-restore.hcl` with the `read` on `transit/keys/backup-kek`; `vault-admin` without the duplicate; role definitions unchanged |
| FW1 | Redacted copy: alias `BACKUP_SOURCES` and the two logged LAN rules, revision by `itadmin@10.10.60.10[10.10.50.49] (RADIUS/RADIUS1)`; no secret element left |
| Old RADIUS1 node | Stopped, kept until this phase is committed, then deleted (its disk holds the RADIUS secrets in clear) |

## Rollback

| Change | Undo |
|---|---|
| Principals file | `rm /etc/ssh/sshd_config.d/11-principals.conf; systemctl reload ssh` (Warpgate certificates work as in Phase 4D) |
| Backup path | `ufw delete` the LOG1 rule on each server; disable FW1 rules 2.2–2.3; `systemctl disable --now ztna-backup.timer` |
| Job credential | `vault write auth/approle/role/backup-job/secret-id-accessor/destroy secret_id_accessor=…` |
| `vault-admin` | `vault policy write vault-admin /tmp/vault-admin.before.hcl` (kept until the end of Step 1) |

## Known limitations (to carry into the report)

- Integrity of an archive against an attacker who is root on LOG1 rests on the copies already
  on Windows and on Vault's audit log (unexpected `transit/sign` calls), not on the manifest
  alone: LOG1 holds the signing credential.
- Logs can be altered on LOG1 before the night's manifest (window up to 24 h); the Wazuh copy
  (Phase 7) covers that window.
- Restore decryption is one person with an `it-admins` login choosing the `backup-restore` role;
  Vault Community has no two-person control. Every decrypt is audited and becomes a Phase 7 alert.
- `vault-admin` can rewrite policies (F4).
