# AppServer's Vault Agent (AppRole "appserver"): read its compose secrets only.
path "secret/data/appserver/compose" {
  capabilities = ["read"]
}
