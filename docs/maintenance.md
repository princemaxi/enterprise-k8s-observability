# Maintenance

## Upgrade procedure (Elastic Stack version)

1. Read the Elastic upgrade notes for the target version — breaking
   mapping/settings changes are common between major versions.
2. Bump `spec.version` in `terraform/modules/logging-platform/templates/elasticsearch.yaml.tpl`
   **and** `terraform/modules/logging-platform/templates/kibana.yaml.tpl` together; ECK does not support
   Kibana running ahead of Elasticsearch's version.
3. Apply. ECK performs a rolling upgrade of data nodes one at a time by
   default, respecting `maxUnavailable`, so the cluster stays available
   throughout — but confirm cluster health is `green` before applying
   (`GET _cluster/health`), not just before starting the change.
4. Watch `kubectl -n elastic-system get elasticsearch logging -w` — ECK
   reports phase transitions (`ApplyingChanges` → `Ready`).
5. Upgrade the ECK operator itself separately — it's a Terraform-managed
   Helm release now (`helm_release.eck_operator` in `addons.tf`), so bump
   its `version` there and `terraform apply`, rather than re-running raw
   `kubectl apply -f .../crds.yaml`/`operator.yaml`. Check the operator's
   own compatibility matrix against the ES/Kibana version you're running
   before bumping either.

## Ad hoc `curl_es`/`$ES_URL` setup

Several commands below assume an authenticated `curl_es` helper and
`$ES_URL` — these aren't a standing script (the automated bootstrap
doesn't need one; see `docs/troubleshooting.md`'s "Manually port-forwarding
to Elasticsearch" entry), so set them up yourself for any ad hoc session:

```bash
kubectl -n elastic-system port-forward svc/logging-es-http 9200 &
kubectl -n elastic-system get secret logging-es-http-certs-public -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
ES_PASS=$(kubectl -n elastic-system get secret logging-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
ES_URL="https://logging-es-http.elastic-system.svc:9200"
curl_es() { curl -sS --cacert ca.crt --resolve logging-es-http.elastic-system.svc:9200:127.0.0.1 -u "elastic:${ES_PASS}" "$@"; }
```

## Rolling restart (config change without version bump)

Most `podTemplate` changes (resource limits, JVM opts, node selectors)
trigger ECK to roll pods automatically. To force one manually (e.g. after
rotating a cert out of band):

```bash
kubectl -n elastic-system delete pod logging-es-data-0
# wait for it to rejoin the cluster (yellow -> green) before touching the next
```

Never delete more than one data node pod at a time unless you've confirmed
the cluster can tolerate it — check `GET _cluster/health` shows `green`
before proceeding to the next.

## Scaling the cluster

Scaling now means editing a Terraform variable and re-applying — never
hand-edit the rendered CR directly, since the next `terraform apply` would
just overwrite that edit.

- **Add data nodes**: edit the live target environment's `terraform.tfvars`
  (not a copied template) to bump `elasticsearch.data_count` (and, if
  genuinely needed, `data_storage_gb`), then `terraform apply` — this updates
  both the Elasticsearch CR's `nodeSets[].count` (via
  `templates/elasticsearch.yaml.tpl`) and the corresponding EKS node group's
  `desired_size` in the same run, so capacity exists before ECK tries to
  schedule the new pods rather than needing two separate applies in the right
  order.
- **Add master nodes**: keep this an odd number (3 or 5) — even numbers
  don't improve quorum tolerance and just cost more.
- **Scale Kibana**: edit the live `kibana.replicas` value in the environment's
  `terraform.tfvars`; stateless, so this is low-risk.

## Snapshot restore (disaster recovery drill)

This should be tested on a schedule, not just documented and forgotten:

```bash
# 1. List available snapshots
curl_es "$ES_URL/_snapshot/s3_repository/_all"

# 2. Restore into a renamed index so it doesn't collide with a live one
curl_es -X POST "$ES_URL/_snapshot/s3_repository/<snapshot-name>/_restore" -d '{
  "indices": "app-logs-*",
  "rename_pattern": "app-logs-(.+)",
  "rename_replacement": "restored-app-logs-$1"
}'

# 3. Verify doc counts / spot-check data before treating the drill as passed
curl_es "$ES_URL/restored-app-logs-*/_count"
```

Run this quarterly at minimum and record the result (time to restore, any
errors) — an untested backup is a hope, not a plan.

## Index cleanup

ILM handles routine deletion at 30 days automatically. For a manual
cleanup (e.g. reclaiming space faster than ILM's schedule after an
incident-driven spike):

```bash
curl_es -X DELETE "$ES_URL/app-logs-000001,app-logs-000002"
```

Never delete the currently active write index (check
`GET _alias/app-logs` for `is_write_index: true`) — that breaks Filebeat's
next bulk write until the alias is repointed.

## Certificate renewal

- **Kibana's public TLS cert**: handled automatically by cert-manager
  (renews ~30 days before expiry). Verify with
  `kubectl -n elastic-system get certificate kibana-ingress-tls`.
- **Internal ECK-managed CA**: ECK auto-rotates the transport/HTTP CA
  before expiry; no manual action needed unless you've overridden it with
  a custom CA, in which case renewal is on you.

## Password rotation

```bash
kubectl -n elastic-system get secret logging-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d
# rotate via the ES API rather than editing the Secret directly:
curl_es -X POST "$ES_URL/_security/user/elastic/_password" \
  -d '{"password": "<new-password>"}'
```

Update anything that authenticates with the rotated credential in the same
change window — a password rotation that isn't propagated everywhere just
breaks ingestion silently until someone notices a gap in the dashboards.
Note that `filebeat-es-credentials` is now a Terraform-managed Secret
(copied from ECK's own auto-generated one via a `data` source in
`filebeat.tf`) — it won't pick up a manually-rotated password until the
next `terraform apply` re-reads that data source, so a rotation done
purely via the ES API leaves Filebeat authenticating with the old password
until you re-apply.
