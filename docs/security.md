# Security

## TLS

- **Transport + HTTP layer (ES ↔ ES, Kibana ↔ ES)**: ECK auto-generates and
  rotates a self-signed CA by default
  (`terraform/modules/logging-platform/templates/elasticsearch.yaml.tpl`,
  `kibana.yaml.tpl`). This is fine for the cluster-internal cert but not for
  anything client-facing.
- **Client-facing (browser ↔ Kibana)**: terminated at the ingress via
  cert-manager, using a Let's Encrypt certificate issued through the
  Route53 DNS-01 solver
  (`terraform/modules/logging-platform/ingress.tf`) — the same pattern
  already in use on `tooling-app-eks`.
- Never disable `xpack.security.http.ssl` / `xpack.security.transport.ssl`;
  ECK enables both by default and nothing in this repo turns them off.

## Authentication and RBAC

- Elasticsearch's built-in `elastic` superuser is used only for one-time
  bootstrap (`terraform/modules/logging-platform/scripts/es-bootstrap-remote.sh`);
  day-to-day access uses scoped roles.
- Create least-privilege ES roles per consumer rather than sharing the
  `elastic` user:

  ```bash
  # Filebeat: write-only to app-logs-*, no read/delete
  curl_es -X POST "$ES_URL/_security/role/filebeat_writer" -d '{
    "indices": [{"names": ["app-logs-*"], "privileges": ["create_doc", "auto_configure"]}]
  }'

  # Kibana read-only analyst role (for anyone who shouldn't manage ILM/index settings)
  curl_es -X POST "$ES_URL/_security/role/log_reader" -d '{
    "indices": [{"names": ["app-logs-*"], "privileges": ["read", "view_index_metadata"]}]
  }'
  ```

- Kibana Spaces + Feature Controls should be used to separate "can view
  dashboards" from "can edit index patterns / manage Watcher" once more
  than one person has access — not covered by manifests here since it's
  configured in-app, but flagged in `docs/maintenance.md`.

## Secrets management

Nothing in this repo hardcodes a credential:

- **Order API** secrets (`DB_PASSWORD`, `EXTERNAL_API_KEY`) are injected by
  the Vault Agent sidecar (`vault.hashicorp.com/agent-inject` annotations
  in `terraform/modules/logging-platform/order-api.tf`), rendered to
  `/vault/secrets/config.env` inside the pod at startup, never passed as
  plain Kubernetes Secret env vars. The secret's actual value is generated
  once (random, via `openssl rand`) and written straight into Vault by
  `scripts/vault-bootstrap.sh` — no human ever sees or types it.
- **Filebeat's Elasticsearch credentials** are copied automatically from
  ECK's own auto-generated `logging-es-elastic-user` Secret via a
  `data "kubernetes_secret_v1"` read in `elasticsearch.tf`, into a new
  Secret Terraform creates directly (`filebeat.tf`) — not a manual
  `kubectl create secret` step, and not Vault-managed (Filebeat, being a
  DaemonSet without the Vault Agent sidecar pattern wired up, reads a
  plain Secret; only the Order API uses Vault injection).
- **cert-manager, the EBS CSI driver, the AWS Load Balancer Controller,
  external-dns, and Vault's own AWS access (KMS auto-unseal)** all use EKS
  Pod Identity — no OIDC federation, no ServiceAccount annotations, a
  simpler trust policy than IRSA.
- **S3 snapshot access** (Elasticsearch → S3) is the one deliberate
  exception: a narrowly-scoped IAM user + access key, loaded into
  Elasticsearch's own keystore. Both IRSA and Pod Identity were tried
  first and both hit open, unresolved upstream bugs specific to
  Elasticsearch's bundled `repository-s3` plugin — see
  `docs/troubleshooting.md` for the full incident history and the
  specific GitHub issues. This is Elastic's own documented fallback for
  exactly this situation, not an oversight; the trade-off is one static,
  tightly-scoped credential instead of a federated one.

## Vault

- **KMS auto-unseal**: Vault's seal key lives in AWS KMS
  (`terraform/modules/logging-platform/vault.tf`), not as Shamir key
  shares a human has to hold and enter after every restart. Vault still
  needs a one-time `vault operator init` (handled automatically by
  `scripts/vault-bootstrap.sh`), but every restart after that auto-unseals
  with zero human involvement.
- **Root token and recovery key**: written directly into a Kubernetes
  Secret (`vault/vault-init`) by the bootstrap script — never printed to a
  terminal, never stored in Terraform state, never touched by a
  copy-paste. Retrieve it only if you genuinely need interactive Vault CLI
  access (`make vault-root-token` prints the retrieval command).
- **Single recovery key** (`-recovery-shares=1 -recovery-threshold=1`,
  not the default 5-share/3-threshold quorum): a deliberate simplification
  for this project's single-operator scope. Before treating any
  environment built from this repo as a real production secret store,
  reconsider this alongside tightening who can read the `vault-init`
  Secret via RBAC — right now, anyone with read access to the `vault`
  namespace's Secrets can retrieve the root token.
- **TLS**: intentionally disabled on Vault's own listener (`tls_disable =
  true` in its raft config) — Vault traffic never leaves the cluster
  network. Revisit before this is a real production secret store, same
  caveat as the recovery-key simplification above.

## Network policies

Default-deny in every namespace (`elastic-system`, `logging`,
`applications`, `vault`), with explicit allow rules layered on top for the
only paths that should exist. Defined as native Terraform resources
(`terraform/modules/logging-platform/network-policies.tf`), not applied as
separate YAML — see `docs/architecture.md`'s "Fully Terraform-native"
section for why. Summary:

| From                          | To                         | Port      |
|--------------------------------|------------------------------|-----------|
| ingress-nginx                  | Kibana                       | 5601      |
| Kibana                         | Elasticsearch                | 9200      |
| Filebeat (logging ns)          | Elasticsearch (elastic-system)| 9200      |
| Elasticsearch pods (internal)  | Elasticsearch pods            | 9200/9300 |
| Elasticsearch                  | S3 (egress, any)              | 443       |
| ingress-nginx                  | Order API                     | 8080      |
| Order API                      | Vault                         | 8200      |

A CNI that enforces `NetworkPolicy` is required — the default AWS VPC CNI
does not enforce policies out of the box; either enable
`ENABLE_NETWORK_POLICY=true` on a recent VPC CNI version, or run Calico
alongside it. Confirm this before assuming these policies are doing
anything.

## Audit logging

Enable Elasticsearch's audit log to capture authentication events, index
access, and security-config changes:

```yaml
# add to elasticsearch.yaml nodeSets[].config
xpack.security.audit.enabled: true
xpack.security.audit.logfile.events.include:
  - authentication_success
  - authentication_failed
  - access_denied
  - connection_denied
```

Audit logs are written to a separate log stream on each ES pod
(`<cluster>-audit.json`) — ship these through Filebeat as a second,
non-app input if audit trail retention is a requirement, since they are
not part of the `app-logs-*` index pattern by default.

## Sensitive field redaction

`app/app.py`'s `JsonFormatter.sanitize()` recursively redacts any dict key
matching `password`, `token`, `secret`, `authorization`, or `api_key`
inside the `business` extra field before the log line is ever written to
stdout — redaction happens at the source, not after the fact in
Elasticsearch. This is deliberately app-side rather than an ES ingest
pipeline or Filebeat processor: by the time a secret reaches Filebeat, it
has already touched the container's log file on disk, which defeats the
purpose. Extend `SENSITIVE_FIELDS` in that class for any additional field
names introduced by future endpoints.

## What's intentionally out of scope here

- **Free-text PII in the `message` field** — the redaction above only
  catches structured `business` fields by key name, not, say, a card
  number someone concatenates into a plain string message. The Order
  API's demo payloads don't do this, but a production version handling
  real payment data would need an ingest pipeline or Filebeat processor
  with pattern-based (regex) redaction as a second layer, since key-based
  redaction can't catch what's buried inside free text.
- **SIEM integration / long-term audit retention beyond this cluster** —
  out of scope for a capstone; flagged here so it isn't mistaken for an
  oversight if a reviewer asks about it.
