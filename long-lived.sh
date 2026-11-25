#!/usr/bin/env bash
# Show that a connection opened with a valid certificate keeps working after
# that certificate expires. Kafka checks validity only during the TLS handshake.
set -euo pipefail
cd "$(dirname "$0")"

PEM=certs/billing-service/billing-service.pem

docker compose stop billing-agent billing-app >/dev/null 2>&1
echo "==> agent stopped, certificate $(openssl x509 -in "$PEM" -noout -enddate)"
echo "==> producing one message every 10s for 200s on a single connection"

docker compose run --rm --no-deps -T --entrypoint bash billing-app -c '
  (for i in $(seq 1 20); do echo "long-$i-$(date -u +%T)"; sleep 10; done) |
  /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server kafka:9092 \
    --topic billing.events --producer.config /etc/client/billing.properties 2>&1 |
  grep -E "ERROR|Exception" || true'

echo "==> first and last message the broker accepted"
docker compose exec -T kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka:9092 --consumer.config /etc/kafka/admin.properties \
  --topic billing.events --from-beginning --timeout-ms 8000 2>/dev/null \
  | grep long- | sed -n '1p;$p'

docker compose --profile apps start billing-agent billing-app >/dev/null 2>&1
echo "==> agent restarted"
