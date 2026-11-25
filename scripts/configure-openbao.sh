#!/bin/sh
# Runs inside the openbao container. Configures the PKI engine, one role per
# identity, and an AppRole that can only issue the billing-service identity.
set -eu

bao secrets enable pki
bao secrets tune -max-lease-ttl=87600h pki
bao write -field=certificate pki/root/generate/internal \
  common_name="Kafka Lab Root CA" key_type=ec key_bits=256 ttl=87600h >/dev/null

bao write pki/roles/kafka-broker \
  allowed_domains=kafka,localhost allow_bare_domains=true allow_subdomains=false \
  allow_localhost=true server_flag=true client_flag=true \
  key_type=ec key_bits=256 max_ttl=720h

bao write pki/roles/kafka-admin \
  allowed_domains=kafka-admin allow_bare_domains=true allow_subdomains=false \
  server_flag=false client_flag=true key_type=ec key_bits=256 max_ttl=8h

# Short-lived application identity. no_store keeps OpenBao from writing every
# issued certificate to storage, which matters at high issue rates.
bao write pki/roles/billing-service \
  allowed_domains=billing-service allow_bare_domains=true allow_subdomains=false \
  allow_ip_sans=false allow_any_name=false enforce_hostnames=false \
  server_flag=false client_flag=true key_type=ec key_bits=256 \
  ttl=2m max_ttl=10m no_store=true

bao policy write billing-service - <<'POL'
path "pki/issue/billing-service" {
  capabilities = ["update"]
}
POL

bao auth enable approle
bao write auth/approle/role/billing-service \
  token_policies=billing-service token_ttl=15m token_max_ttl=1h
