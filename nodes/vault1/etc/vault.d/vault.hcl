# Vault on VAULT1 (Extension Phase 4). Single node, integrated storage, TLS from the lab CA.
ui            = true
enable_unauthenticated_access = ["generate-root"]   # break-glass: root token from 3 unseal keys, no login needed (Vault 2.x default is [])
disable_mlock = true          # recommended with raft; swap is off on this host
api_addr      = "https://vault.ztna.lab:8200"
cluster_addr  = "https://127.0.0.1:8201"

storage "raft" {
  path    = "/var/lib/vault/data"
  node_id = "vault1"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "127.0.0.1:8201"
  tls_cert_file   = "/etc/vault.d/tls/vault.crt"
  tls_key_file    = "/etc/vault.d/tls/vault.key"
  tls_min_version = "tls12"
}
