# LOG1's nightly job: SSH certificates for ztnabackup, raft snapshot, manifest signatures. No decrypt.
path "ssh-client-signer/sign/backup"  { capabilities = ["update"] }
path "sys/storage/raft/snapshot"      { capabilities = ["read"] }
path "transit/sign/manifest-sign"     { capabilities = ["update"] }
path "transit/verify/manifest-sign"   { capabilities = ["update"] }
