#!/usr/bin/env bash
# ==============================================================================
# Lab Verification Suite
# Exercises Kafka topic authorization, OpenBao PKI identity restrictions,
# CA trust validation, automated certificate rotation, and expiry enforcement.
# Estimated runtime: ~5 minutes
# ==============================================================================

set -euo pipefail
cd "$(dirname "$0")"

# --- Configuration & Constants ------------------------------------------------
readonly CERT_PEM="certs/billing-service/billing-service.pem"
readonly CA_PEM="certs/ca.pem"
readonly ROGUE_DIR="certs/rogue"
readonly ROTATION_TIMEOUT_SEC=240

# --- Terminal Formatting ------------------------------------------------------
if [[ -t 1 ]]; then
  readonly GREEN='\033[0;32m'
  readonly RED='\033[0;31m'
  readonly BLUE='\033[0;34m'
  readonly DIM='\033[2m'
  readonly NC='\033[0m'
else
  readonly GREEN='' RED='' BLUE='' DIM='' NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0

# --- Cleanup Trap -------------------------------------------------------------
cleanup() {
  rm -rf "$ROGUE_DIR"
  # Ensure services stopped during the expiry test are always brought back up
  docker compose --profile apps start billing-agent billing-app >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- Logging & Assertion Helpers ----------------------------------------------
section() {
  printf "\n${BLUE}==> %s${NC}\n" "$1"
}

info() {
  printf "  ${DIM}%s${NC}\n" "$1"
}

pass() {
  printf "  ${GREEN}[PASS]${NC} %s\n" "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf "  ${RED}[FAIL]${NC} %s\n" "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_contains() {
  local haystack="$1" needle="$2" success_msg="$3" fail_msg="$4"
  if grep -qE "$needle" <<<"$haystack"; then
    pass "$success_msg"
  else
    fail "$fail_msg (Output: $haystack)"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" success_msg="$3" fail_msg="$4"
  if ! grep -qE "$needle" <<<"$haystack"; then
    pass "$success_msg"
  else
    fail "$fail_msg (Output: $haystack)"
  fi
}

# --- Domain Helpers -----------------------------------------------------------
get_cert_serial() {
  openssl x509 -in "$CERT_PEM" -noout -serial | cut -d= -f2
}

get_cert_expiry() {
  openssl x509 -in "$CERT_PEM" -noout -enddate | cut -d= -f2
}

# Sends a single timestamped message to a Kafka topic and returns combined output
produce_message() {
  local topic="$1"
  local config_path="${2:-/etc/client/billing.properties}"

  docker compose run --rm --no-deps -T --entrypoint bash \
    -v "$PWD/$ROGUE_DIR:/rogue:ro" billing-app -c "
      echo \"test-\$(date +%s)\" | /opt/kafka/bin/kafka-console-producer.sh \
        --bootstrap-server kafka:9092 \
        --topic \"$topic\" \
        --producer.config \"$config_path\" \
        --producer-property max.block.ms=10000 2>&1
    " || true
}

# Executes an OpenBao CLI command authenticated as the billing-service AppRole
bao_as_billing_service() {
  local token="$1"
  shift
  docker compose exec -T -e BAO_TOKEN="$token" openbao bao "$@" 2>&1 || true
}

# --- Test Scenarios -----------------------------------------------------------

test_kafka_authorization() {
  section "1. Kafka Topic Authorization"

  local out
  out=$(produce_message "billing.events")
  assert_not_contains "$out" "ERROR|Exception" \
    "Allowed to write to 'billing.events'" \
    "Unexpectedly rejected from 'billing.events'"

  out=$(produce_message "payments.events")
  assert_contains "$out" "TopicAuthorizationException" \
    "Denied write access to 'payments.events' (TopicAuthorizationException)" \
    "Expected TopicAuthorizationException for 'payments.events'"
}

test_openbao_identity_restrictions() {
  section "2. OpenBao PKI Identity & TTL Restrictions"

  local role_id secret_id token out
  role_id=$(<agent/billing-service/role_id)
  secret_id=$(<agent/billing-service/secret_id)
  token=$(docker compose exec -T openbao bao write -field=token \
    auth/approle/login role_id="$role_id" secret_id="$secret_id")

  # Attempt 1: Spoofing another service's Common Name
  out=$(bao_as_billing_service "$token" write pki/issue/billing-service common_name=payments-service)
  assert_contains "$out" "not allowed by this role" \
    "Refused certificate issuance for unauthorized CN (payments-service)" \
    "Should have refused CN=payments-service"

  # Attempt 2: Accessing a privileged PKI role
  out=$(bao_as_billing_service "$token" write pki/issue/kafka-admin common_name=kafka-admin)
  assert_contains "$out" "permission denied" \
    "Refused access to privileged 'kafka-admin' PKI role" \
    "Should have refused access to kafka-admin role"

  # Attempt 3: Requesting a TTL exceeding role max_ttl
  out=$(bao_as_billing_service "$token" write -format=json pki/issue/billing-service \
    common_name=billing-service ttl=24h | jq -r '.warnings[]?')
  assert_contains "$out" 'maxTTL "10m0s", so maxTTL is being used' \
    "Capped requested 24h TTL down to role max_ttl (10m)" \
    "Failed to cap requested 24h TTL"
}

test_untrusted_ca_rejection() {
  section "3. CA Trust Validation (Rogue Self-Signed Certificate)"

  mkdir -p "$ROGUE_DIR"

  # Generate a self-signed cert claiming to be billing-service
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj "/CN=billing-service" \
    -keyout "$ROGUE_DIR/key.pem" \
    -out "$ROGUE_DIR/cert.pem" 2>/dev/null

  cat "$ROGUE_DIR/key.pem" "$ROGUE_DIR/cert.pem" > "$ROGUE_DIR/rogue.pem"
  cp "$CA_PEM" "$ROGUE_DIR/ca.pem"

  sed 's#/certs/billing-service.pem#/rogue/rogue.pem#; s#/certs/ca.pem#/rogue/ca.pem#' \
    client/billing.properties > "$ROGUE_DIR/client.properties"

  local out
  out=$(produce_message "billing.events" "/rogue/client.properties")
  assert_contains "$out" "SslAuthenticationException" \
    "TLS handshake refused rogue self-signed certificate" \
    "Rogue self-signed certificate was unexpectedly accepted"
}

test_certificate_rotation() {
  section "4. Automated OpenBao Agent Certificate Rotation"

  local initial_serial new_serial elapsed=0
  initial_serial=$(get_cert_serial)
  info "Current serial: $initial_serial (expires: $(get_cert_expiry))"
  info "Polling up to ${ROTATION_TIMEOUT_SEC}s for rotation..."

  while [[ "$(get_cert_serial)" == "$initial_serial" ]]; do
    if (( elapsed >= ROTATION_TIMEOUT_SEC )); then
      fail "Certificate did not rotate within ${ROTATION_TIMEOUT_SEC}s"
      return
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  new_serial=$(get_cert_serial)
  pass "Rotated serial to $new_serial (expires: $(get_cert_expiry))"

  local out
  out=$(produce_message "billing.events")
  assert_not_contains "$out" "ERROR|Exception" \
    "Kafka write succeeded using newly rotated certificate" \
    "Kafka write failed after certificate rotation"
}

test_certificate_expiry_enforcement() {
  section "5. Expired Certificate Rejection"

  docker compose stop billing-agent billing-app >/dev/null 2>&1

  local expiry_str expiry_epoch now_epoch wait_seconds
  expiry_str=$(get_cert_expiry)
  # Support both BSD/macOS (date -j) and GNU/Linux (date -d)
  expiry_epoch=$(date -j -f '%b %e %T %Y %Z' "$expiry_str" +%s 2>/dev/null || date -d "$expiry_str" +%s)
  now_epoch=$(date +%s)
  wait_seconds=$(( expiry_epoch - now_epoch + 5 ))

  if (( wait_seconds > 0 )); then
    info "Agent stopped. Waiting ${wait_seconds}s for certificate to expire..."
    sleep "$wait_seconds"
  fi

  local out
  out=$(produce_message "billing.events")
  assert_contains "$out" "SslAuthenticationException" \
    "TLS handshake refused expired certificate" \
    "Expired certificate was unexpectedly accepted"

  docker compose --profile apps start billing-agent billing-app >/dev/null 2>&1
}

# --- Main Execution -----------------------------------------------------------
main() {
  test_kafka_authorization
  test_openbao_identity_restrictions
  test_untrusted_ca_rejection
  test_certificate_rotation
  test_certificate_expiry_enforcement

  printf "\n========================================\n"
  printf "Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$PASS_COUNT" "$FAIL_COUNT"
  printf "========================================\n"

  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"