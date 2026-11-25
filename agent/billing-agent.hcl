pid_file = "/tmp/agent.pid"

vault {
  address = "http://openbao:8200"
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/agent/creds/role_id"
      secret_id_file_path                 = "/agent/creds/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }
}

template_config {
  exit_on_retry_failure = true
}

# Key and certificate go in one file because Kafka's PEM keystore expects both
# together. pkiCert re-issues the certificate before it expires.
template {
  destination = "/certs/billing-service.pem"
  perms       = "0644"
  contents    = <<-EOT
  {{- with pkiCert "pki/issue/billing-service" "common_name=billing-service" "ttl=2m" "private_key_format=pkcs8" -}}
  {{ .Key }}
  {{ .Cert }}
  {{- end }}
  EOT
}
