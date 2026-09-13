# Troubleshooting Guide

Each entry: symptom → likely cause → resolution → how to prevent it
recurring.

## Elasticsearch pod stuck `Pending`

- **Cause**: PVC can't bind — either the `es-gp3` StorageClass wasn't
  applied yet, or the EBS CSI driver add-on/IRSA role isn't working.
- **Resolution**:
  ```bash
  kubectl -n elastic-system describe pod logging-es-data-0
  kubectl get storageclass es-gp3
  kubectl -n kube-system logs -l app=ebs-csi-controller -c csi-provisioner
  ```
  Confirm `aws_eks_addon.ebs_csi` applied cleanly and the node has the
  `AmazonEBSCSIDriverPolicy` attached.
- **Prevention**: apply `storageclass.yaml` before `elasticsearch.yaml` —
  order matters, ECK won't retry-create a StorageClass for you.

## Elasticsearch pod stuck `Pending` — no matching nodes

- **Cause**: node group taints/labels don't match the `nodeSelector` /
  `tolerations` in `elasticsearch.yaml`, or the `es-data`/`es-master` node
  group hasn't finished scaling up in AWS yet.
- **Resolution**: `kubectl get nodes -L role` should show nodes labeled
  `role=es-data` / `role=es-master`. If missing, check the EKS node group
  status in the AWS console — it may still be launching instances.

## Filebeat not shipping logs

- **Cause 1**: pod missing the `co.elastic.logs/enabled: "true"`
  annotation — Filebeat's autodiscover config in `values.yaml` explicitly
  ignores unannotated pods by design.
- **Cause 2**: wrong log path / container ID mismatch after a pod restart.
- **Resolution**:
  ```bash
  kubectl -n logging logs -l app.kubernetes.io/name=filebeat --tail=100
  # Look for "Non-zero metrics in the last 30s" — harvester/output counts should be non-zero
  kubectl -n applications get pod -l app=order-api -o jsonpath='{.items[0].metadata.annotations}'
  ```
- **Prevention**: bake the annotation into the Deployment template (already
  done in `terraform/modules/logging-platform/order-api.tf`) rather than adding it by hand per pod.

## Kibana cannot connect to Elasticsearch

- **Cause**: usually one of — ES not yet `green`/`yellow` (still
  starting), wrong `elasticsearchRef`, or a CA trust mismatch if a custom
  cert was swapped in without updating Kibana's trust config.
- **Resolution**:
  ```bash
  kubectl -n elastic-system get elasticsearch,kibana
  kubectl -n elastic-system logs -l kibana.k8s.elastic.co/name=logging
  ```
  Look for `ConnectionError` vs `AuthenticationException` — they point to
  different layers (network/TLS vs credentials).

## Cluster health is `yellow`

- **Cause**: unassigned replica shards — most commonly because there
  aren't enough data nodes/AZs to satisfy the replica count's anti-affinity
  requirement (e.g. 1 replica needs at least 2 nodes across 2 AZs).
- **Resolution**:
  ```bash
  curl_es "$ES_URL/_cluster/allocation/explain?pretty"
  ```
  This tells you exactly why a shard won't allocate — read the actual
  `explanation` field rather than guessing.
- **Note**: `yellow` is not an outage — reads/writes still work. Don't
  treat it with the same urgency as `red`, but don't ignore it either.

## Cluster health is `red`

- **Cause**: a primary shard is unassigned — data loss risk if this
  persists.
- **Resolution**: same `_cluster/allocation/explain` call; if the cause is
  a lost data node, prioritize getting a replacement node schedulable
  before doing anything else. If no replica exists to promote, this is a
  restore-from-snapshot situation — see `docs/maintenance.md`.

## High JVM memory / frequent GC pauses on data nodes

- **Cause**: heap sized too small for indexing rate, or a query pattern
  (e.g. unbounded aggregations, deep pagination) pulling too much into
  heap at once.
- **Resolution**: check `GET _nodes/stats/jvm` for GC frequency/duration.
  If genuinely under-provisioned, scale `es-data` node count rather than
  just raising heap past 50% of container memory — that starves the OS
  page cache and makes things worse, not better.

## Filebeat backpressure / growing queue

- **Cause**: Elasticsearch temporarily unavailable or overwhelmed (e.g.
  during a rolling restart), so Filebeat's memory queue fills.
- **Resolution**: this is expected and handled — `queue.mem` is bounded at
  4096 events with retry/backoff (`values.yaml`), so Filebeat won't OOM the
  node; it will apply backpressure and catch up once ES recovers. Confirm
  with `filebeat.harvester` metrics in its own logs that events resume
  flowing once ES is healthy again.

## Filebeat ships logs fine initially, then log volume grows unbounded / old data never ages out

- **Cause**: `terraform/modules/logging-platform/filebeat.tf`'s
  `output.elasticsearch.index` was set to the concrete bootstrap index
  name (`app-logs-000001`) instead of the rollover write alias
  (`app-logs`). Writing to a concrete index instead of the alias defeats
  ILM rollover entirely — once the hot phase rolls over to
  `app-logs-000002`, Filebeat keeps writing to the now-frozen `-000001`
  forever instead of following the alias to the new write index, so the
  original index just keeps growing past its intended size/age limit.
- **Resolution**: already fixed — `output.elasticsearch.index: "app-logs"`
  (the alias, not a concrete index).
- **Prevention**: whenever ILM rollover is involved, the *only* thing any
  writer should ever target is the alias — never a concrete index name,
  even the "current" one, since which index that alias actually points at
  changes over time by design.

## Ingress / cert-manager: Kibana cert stuck `pending`

- **Cause**: Route53 DNS-01 challenge failing — usually a missing/incorrect
  `hostedZoneID` in the `ClusterIssuer`, or the cert-manager IRSA role
  lacking `route53:ChangeResourceRecordSets` on the right zone.
- **Resolution**:
  ```bash
  kubectl describe certificate kibana-ingress-tls -n elastic-system
  kubectl -n cert-manager logs -l app=cert-manager | grep -i route53
  ```

## `terraform apply`: `InvalidParameterException: Requested AMI for this version X.XX is not supported`

- **Cause**: the pinned `cluster_version` has reached (or is about to reach)
  end of EKS extended support, and AWS has stopped publishing new managed
  node group AMIs for it — the control plane may still accept the version,
  but `CreateNodegroup` will reject it. This is a version-lifecycle issue,
  not a configuration mistake — it will happen again in the future once
  whatever version is pinned next also ages out.
- **Resolution**: check currently valid versions and addon compatibility
  directly rather than trusting any static doc (EKS version support windows
  shift over time):
  ```bash
  aws eks describe-addon-versions --kubernetes-version <candidate> \
    --addon-name aws-ebs-csi-driver --query 'addons[].addonVersions[0].addonVersion' --output text
  ```
  Bump `cluster_version` in `terraform/environments/<env>/variables.tf`.
- **Prevention**: don't let `cluster_version` sit unreviewed for a long
  period — EKS versions have a fixed support lifecycle (roughly 14 months
  standard + 12 months extended from GA).

## `terraform apply`: `Unsupported Kubernetes minor version update from X.XX to Y.YY`

- **Cause**: EKS only allows sequential single-minor-version upgrades
  (1.30→1.31→1.32...) — a `cluster_version` bump on an *existing* cluster
  can't jump multiple minor versions in one `UpdateClusterVersion` call.
- **Resolution**: for a cluster with no real workload/data yet, it's
  faster to `terraform destroy` and recreate fresh at the target version
  than to walk the upgrade path one minor version at a time. A cluster
  already holding real data has no choice but to walk it sequentially.
- **Prevention**: get `cluster_version` right before the first real
  `apply` — see the entry above for how to check.

## Manually port-forwarding to Elasticsearch: `SSL: no alternative certificate subject name matches target host name 'localhost'`

- **Cause**: ECK's self-signed cert for the Elasticsearch HTTP layer only
  covers the real in-cluster service DNS name (`logging-es-http.elastic-system.svc`
  and variants) in its SAN list — never `localhost`, since ECK has no way
  to know you'll reach it via `kubectl port-forward`. The cert itself is
  entirely valid; only the hostname check fails.
- **This doesn't affect the automated build** — `scripts/es-bootstrap.sh`
  runs its curl calls from *inside* the cluster via `kubectl exec` into an
  Elasticsearch pod itself (see that script's header comment), addressing
  ES by its real service hostname directly and using the CA cert Elastic's
  own documentation specifies for exactly this case
  (`/usr/share/elasticsearch/config/http-certs/ca.crt`), never a
  port-forward at all.
- **If you manually port-forward for your own debugging**, don't reach
  for `-k`/`--insecure` — that skips the whole CA chain check, not just
  the hostname. Use curl's `--resolve` instead, keeping the connection
  pointed at `127.0.0.1` while presenting the real service hostname for
  TLS verification:
  ```bash
  kubectl -n elastic-system port-forward svc/logging-es-http 9200 &
  kubectl -n elastic-system get secret logging-es-http-certs-public -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
  curl --cacert ca.crt --resolve logging-es-http.elastic-system.svc:9200:127.0.0.1 \
    "https://logging-es-http.elastic-system.svc:9200/..."
  ```
- **Prevention**: none needed for the automated path — this only matters
  if you're doing ad hoc manual debugging outside what Terraform already
  runs.

## Vault Agent annotations present, but `DB_PASSWORD`/`EXTERNAL_API_KEY` never populated in the Order API pod

- **Cause**: the `vault.hashicorp.com/agent-inject` annotations only do
  something if the **Vault Agent Injector** — a mutating admission
  webhook — is actually running in the cluster. If you're seeing this,
  check whether `helm_release.vault` (terraform/modules/logging-platform/vault.tf)
  actually applied successfully — the injector comes up as part of that
  same release (`injector.enabled = true` in its values), not as a
  separate manual step.
- **Resolution**: confirm the injector pod is running:
  ```bash
  kubectl -n vault get pods -l app.kubernetes.io/name=vault-agent-injector
  ```
  Then confirm the Order API pod actually got a sidecar injected:
  ```bash
  kubectl -n applications get pod <order-api-pod> -o jsonpath='{.spec.containers[*].name}'
  ```
  You should see a `vault-agent` container alongside `order-api`, not just
  the app container alone. If the injector pod isn't running, re-check
  `terraform apply` output for errors on `helm_release.vault` specifically
  — a chart install failure there wouldn't necessarily fail the whole
  `apply` loudly depending on what else succeeded.
- **Prevention**: none needed beyond what's already automated — this
  entry exists mainly to explain what "no vault-agent container" actually
  means diagnostically, in case the Helm release itself silently degrades
  between `terraform apply` runs (e.g. someone manually deletes the
  injector deployment out-of-band).

## Order API's Vault Agent sidecar can't reach Vault (connection refused / timeout on port 8200)

- **Cause**: Vault runs in-cluster now (`vault.vault.svc` — see
  `terraform/modules/logging-platform/vault.tf`), and the Order API's
  `NetworkPolicy` egress rule explicitly allows this via a
  `namespaceSelector: {name: vault}` rule
  (`terraform/modules/logging-platform/network-policies.tf`). If this
  breaks, the first thing to check is whether that rule and the `vault`
  namespace's own `default-deny-all` + `vault-allow-ingress-and-kms-egress`
  policies are both actually applied — a namespace with default-deny
  Ingress but no explicit allow for traffic *from* `applications` would
  silently drop the Vault Agent's calls with no obvious client-side error
  beyond a generic timeout.
- **Resolution**:
  ```bash
  kubectl -n vault get networkpolicy
  kubectl -n applications describe networkpolicy order-api-allow-ingress-and-vault
  ```
  Confirm both sides of the rule exist and reference the right namespace
  labels (`kubectl get ns vault --show-labels`).
- **Prevention**: whenever a dependency moves between "external" and
  "in-cluster" (as Vault did in this project, from an earlier
  externally-hosted assumption to the current Terraform-managed in-cluster
  deployment), re-check every NetworkPolicy that references it — a rule
  written for one topology silently stops making sense for the other, and
  Kubernetes won't warn you about it.

## Elasticsearch snapshot repository: why this project uses a plain IAM user instead of IRSA or EKS Pod Identity

This isn't a bug to fix — it's the resolution of one, documented here so
nobody "helpfully" reverts it back to federated identity later without
knowing why. The short version: **both** federated-identity mechanisms
were tried, in order, and both hit real, currently-open upstream bugs
specific to Elasticsearch's bundled `repository-s3` plugin.

**Attempt 1 — IRSA.** Symptom: snapshot registration failed with
`AccessDenied`, and the identity in the error was the EC2 node's own
instance role, not the IRSA role — meaning the pod never actually assumed
the IRSA identity at all. Root causes, layered:
1. ECK doesn't auto-create a dedicated ServiceAccount per Elasticsearch
   resource, so without one existing and IRSA-annotated, there's nothing
   for the AWS Pod Identity webhook to act on — it fails *silently*,
   falling back to the node role rather than erroring loudly.
2. Even after fixing that: `repository-s3` doesn't use the generic AWS
   SDK credential chain. It looks for the web identity token at exactly
   one hardcoded path, `config/repository-s3/aws-web-identity-token-file`
   (Elastic's own documented requirement), and ignores wherever the EKS
   webhook mounts the token by default — so `AWS_ROLE_ARN` being correctly
   injected still isn't enough on its own.
3. Even after fixing *that*: multiple open Elasticsearch GitHub issues
   (elastic/elasticsearch#101828, elastic/elasticsearch#115186) report ES
   never reloading the token file after Kubernetes refreshes it on disk —
   snapshots work initially, then fail again hours later, fixable only by
   a rolling restart. Unresolved upstream as of when this was written.

**Attempt 2 — EKS Pod Identity.** The obvious next move — Pod Identity is
the newer, simpler AWS mechanism, no OIDC federation, no ServiceAccount
annotations. It genuinely is a real improvement for cert-manager and the
EBS CSI driver in this project (see `pod-identity.tf`). For Elasticsearch
specifically, though: ES 8.15.0 bundles an AWS SDK version old enough to
predate Pod Identity support entirely (added only in SDK v2 2.21.30+), so
the credential URI Pod Identity injects gets rejected with `"The full URI
(http://169.254.170.23/v1/credentials)... has an invalid host"` — see
elastic/cloud-on-k8s#8320, open and unresolved as of when this was
written.

**What's actually deployed**: a narrowly-scoped IAM user (access to
nothing but this one S3 bucket — `aws_iam_user.es_snapshots` in
`terraform/modules/logging-platform/s3.tf`), loaded into Elasticsearch's
own keystore via `spec.secureSettings` on the Elasticsearch CR. This is
Elastic's own documented fallback for exactly this situation, and has no
equivalent open bugs against it. The trade-off is a static, long-lived
credential instead of a federated one — acceptable here because it's
scoped to a single bucket and nothing else, but worth knowing if you're
evaluating this repo's security posture: it's a deliberate, documented
exception to "no static credentials," not an oversight.

If this ever needs revisiting (e.g. once the upstream SDK bugs are
fixed), check both linked GitHub issues for their current status before
reverting — don't just retry the old approach and assume it'll work
differently this time.

## Order API pod `CrashLoopBackOff` immediately after Vault Agent init, no useful error in `kubectl logs`

- **Cause**: `readOnlyRootFilesystem: true` is set on the container, but
  nothing mounts a writable `/tmp`. Gunicorn's worker heartbeat mechanism
  (used to detect and restart hung workers) writes a temp file per worker
  via Python's `tempfile` module, which defaults to `/tmp` — with the root
  filesystem read-only and no `/tmp` volume, that write fails and the
  worker can't start.
- **Resolution**: already fixed — `terraform/modules/logging-platform/order-api.tf`
  mounts an `emptyDir` volume at `/tmp`.
- **Prevention**: `readOnlyRootFilesystem: true` is the right default for
  every container in this repo, but it's not free — any process that
  writes anywhere at runtime (temp files, caches, sockets) needs an
  explicit `emptyDir` for that specific path. Check what a base image's
  entrypoint actually does before assuming a read-only root "just works."
