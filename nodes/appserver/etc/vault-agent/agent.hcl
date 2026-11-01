# Vault Agent on AppServer (Extension Phase 4C): renders the compose secrets into RAM.
pid_file = "/run/vault-agent/agent.pid"

vault {
  address = "https://vault.ztna.lab:8200"
  ca_cert = "/etc/ssl/ztna/ztna-ca.crt"
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/etc/vault-agent/role-id"
      secret_id_file_path                 = "/etc/vault-agent/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
}

template_config {
  static_secret_render_interval = "1m"
  exit_on_retry_failure         = true
}

template {
  source      = "/etc/vault-agent/compose.env.ctmpl"
  destination = "/run/vault-agent/compose.env"
  perms       = "0600"
  exec {
    command = ["/usr/bin/docker", "compose", "--project-directory", "/home/labadmin/ztna", "up", "-d"]
    timeout = "180s"
  }
}
