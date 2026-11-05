# Restore only: unwrap the passphrase of a backup, verify manifests.
# Reading the key's description (type, versions, public key; never the private key) is what the
# Vault UI needs before it shows the Decrypt form.
path "transit/keys/backup-kek"        { capabilities = ["read"] }
path "transit/decrypt/backup-kek"     { capabilities = ["update"] }
path "transit/verify/manifest-sign"   { capabilities = ["update"] }
