#!/usr/bin/env bash
# Produce one event every 15 seconds. Each run starts a new JVM, so it always
# reads the certificate the agent most recently wrote.
set -u

until [ -s /certs/billing-service.pem ]; do
  echo "waiting for certificate"
  sleep 2
done

while true; do
  msg="invoice-$(date +%s)"
  if echo "${msg}" | /opt/kafka/bin/kafka-console-producer.sh \
      --bootstrap-server kafka:9092 \
      --topic billing.events \
      --producer.config /etc/client/billing.properties \
      --producer-property max.block.ms=10000 2>/tmp/err; then
    echo "$(date -u +%T) sent ${msg}"
  else
    echo "$(date -u +%T) FAILED: $(grep -m1 -E 'Exception|ERROR' /tmp/err)"
  fi
  sleep 15
done
