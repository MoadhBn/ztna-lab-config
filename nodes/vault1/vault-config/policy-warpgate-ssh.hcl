# Warpgate on PAM1: request SSH certificates from role "warpgate", nothing else.
path "ssh-client-signer/sign/warpgate" {
  capabilities = ["update"]
}
