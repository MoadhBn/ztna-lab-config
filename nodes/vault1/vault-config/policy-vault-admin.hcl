# Vault administrators (Keycloak group it-admins). Extension Phase 4B, updated in 4D.
path "sys/auth"            { capabilities = ["read", "list"] }
path "sys/auth/*"          { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/policies/*"      { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/policy/*"        { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/mounts"          { capabilities = ["read", "list"] }
path "sys/mounts/*"        { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/leases/*"        { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/capabilities*"   { capabilities = ["update"] }
path "sys/health"          { capabilities = ["read", "sudo"] }
path "sys/storage/raft/*"  { capabilities = ["read", "list"] }
path "identity/*"          { capabilities = ["create", "read", "update", "delete", "list"] }
path "auth/*"              { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "secret/*"            { capabilities = ["create", "read", "update", "patch", "delete", "list"] }
path "ssh-client-signer/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "transit/*"           { capabilities = ["create", "read", "update", "delete", "list"] }
# Break-glass secrets: administrators may store and replace them, never read or destroy them.
# Reading needs a root token generated from 3 unseal keys (vault operator generate-root).
path "secret/data/breakglass/*"     { capabilities = ["create", "update"] }
path "secret/metadata/breakglass/*" { capabilities = ["read", "list"] }
path "secret/delete/breakglass/*"   { capabilities = ["deny"] }
path "secret/destroy/breakglass/*"  { capabilities = ["deny"] }
# Never the audit devices.
path "sys/audit"           { capabilities = ["read", "list", "sudo"] }
path "sys/audit/*"         { capabilities = ["deny"] }
path "sys/audit-hash/*"    { capabilities = ["deny"] }

# Extension Phase 5: administrators cannot read backups or extract the backup key
path "transit/decrypt/backup-kek"      { capabilities = ["deny"] }
path "transit/keys/backup-kek/config"  { capabilities = ["deny"] }
path "transit/export/*"                { capabilities = ["deny"] }
path "transit/backup/*"                { capabilities = ["deny"] }
path "transit/verify/manifest-sign"    { capabilities = ["update"] }
