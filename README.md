<p align="center">
  <a href="https://digitalis.io">
    <img src="https://cdn.prod.website-files.com/68370d67a3c849c28c22f703/68370d67a3c849c28c22f803_digitalis-logo.svg" alt="Digitalis.IO" width="300">
  </a>
</p>

<p align="center">
  <em>Built and maintained by <a href="https://digitalis.io">Digitalis.IO</a></em>
</p>

# kafka-mtls-openbao

A Docker Compose lab where **every Kafka client identity is a short-lived X.509 certificate issued by OpenBao**, and Kafka ACLs are bound to static principal names.

Kafka has no dynamic secrets engine the way Postgres and Cassandra do. The practical equivalent is to make the identity dynamic and keep authorisation static: OpenBao's PKI engine issues a two minute certificate with `CN=billing-service`, OpenBao Agent renews it before it expires, and the broker maps that CN to `User:billing-service` for its ACLs. No passwords exist anywhere in the lab.

## Quick start

Requires Docker with Compose, `jq` and `openssl`.

```bash
./setup.sh      # about 1 minute
./test.sh       # about 5 minutes, waits for a real rotation and a real expiry
./teardown.sh
```

## What is running

| Service | Image | Role |
|---------|-------|------|
| `openbao` | `openbao/openbao:2.4.1` | Dev mode server, PKI engine and AppRole auth. UI on <http://localhost:8200>, token `root` |
| `kafka` | `apache/kafka:4.1.0` | Single KRaft node. SSL listeners only, `ssl.client.auth=required`, `StandardAuthorizer` |
| `billing-agent` | `openbao/openbao:2.4.1` | `bao agent` logs in with AppRole and writes `certs/billing-service/billing-service.pem` |
| `billing-app` | `apache/kafka:4.1.0` | Produces to `billing.events` every 15 seconds using whatever certificate is on disk |

```text
billing-agent --AppRole login--> openbao --issues CN=billing-service, ttl 2m
      |
      v writes key + cert (PEM)
billing-app --mTLS--> kafka   principal User:billing-service --> ACL: Write billing.events
```

## Examples

Watch the application and the agent across a rotation:

```bash
docker compose logs -f billing-app billing-agent
openssl x509 -in certs/billing-service/billing-service.pem -noout -subject -serial -dates
```

Try to get a certificate for another service with the application's AppRole:

```bash
TOKEN=$(docker compose exec -T openbao bao write -field=token auth/approle/login \
  role_id="$(cat agent/billing-service/role_id)" secret_id="$(cat agent/billing-service/secret_id)")
docker compose exec -T -e BAO_TOKEN="$TOKEN" openbao \
  bao write pki/issue/billing-service common_name=payments-service
# common name payments-service not allowed by this role
```

Show that an open connection outlives its certificate:

```bash
./long-lived.sh
# long-1-22:01:53
# long-20-22:05:04     (certificate expired at 22:03:20)
```

## What `test.sh` checks

| Check | Expected result |
|-------|-----------------|
| `billing-service` writes to `billing.events` | Accepted |
| `billing-service` writes to `payments.events` | `TopicAuthorizationException` |
| AppRole requests `CN=payments-service` | Refused by the PKI role |
| AppRole requests from the `kafka-admin` role | Refused by policy |
| AppRole requests a 24h certificate | Capped at the role `max_ttl` of 10m |
| Self-signed certificate with `CN=billing-service` | TLS handshake refused |
| Agent running for one TTL | New serial, writes still accepted |
| Agent stopped past `notAfter` | TLS handshake refused |

## Configuration

| Setting | Where | Value | Why |
|---------|-------|-------|-----|
| `ssl.principal.mapping.rules` | `kafka/server.properties` | `RULE:^CN=([a-zA-Z0-9._-]+)$/$1/,DEFAULT` | ACLs name `User:billing-service`, not the full DN |
| `super.users` | `kafka/server.properties` | `User:kafka;User:kafka-admin` | The broker authenticates to itself over SSL, including the controller listener |
| `ssl.keystore.type` | broker and clients | `PEM` | Uses OpenBao output directly, no JKS or PKCS12 conversion |
| `ttl` / `max_ttl` | `pki/roles/billing-service` | `2m` / `10m` | Lab values so rotation is visible. Hours is more typical |
| `no_store` | `pki/roles/billing-service` | `true` | Short-lived certificates are not written to OpenBao storage |
| `private_key_format` | agent template | `pkcs8` | Kafka's PEM keystore only reads PKCS#8 keys |

## Findings worth knowing

- **Expiry is checked at handshake only.** A producer connected before `notAfter` keeps writing after it. Short TTLs limit new connections, not existing ones. Revocation needs a CRL or OCSP check, or forcing reconnection.
- **The Java client does not reload its keystore.** `billing-app` starts a new JVM per message, which is why rotation is invisible to it. A long-running application must reconnect or restart to pick up a new certificate.
- **Agent rotation timing.** `pkiCert` re-issued at about 70% of the certificate's lifetime in this lab.
- **Key and certificate must be in one template.** Each `pkiCert` call issues a new certificate, so separate files for key and certificate would not match.

## Limitations

- OpenBao runs in dev mode: in-memory storage, root token, no TLS on the API. Restarting the container loses the CA, so run `./teardown.sh && ./setup.sh`.
- A single root CA issues every certificate. Production should issue from an intermediate.
- The broker certificate is issued once by `setup.sh` with a 30 day TTL and is not rotated.
- One broker, replication factor 1.

## Contact

Maintained by [Digitalis.io](https://digitalis.io). Support at [digitalis.io/contact](https://digitalis.io/contact).

We run Kafka, Cassandra and secrets management platforms in production for customers 24x7.

## License

See [LICENSE](LICENSE) for details.
