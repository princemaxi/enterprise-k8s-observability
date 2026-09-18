# Architecture

## Overview

## Terraform state boundary

Terraform is split into two roots per environment. The infrastructure root
owns only AWS resources and exports the EKS name, endpoint, CA, region, VPC,
ECR, S3, KMS, and IAM values needed by the platform. The platform root reads
those values with `data.terraform_remote_state.infrastructure` and is the
only root that configures the Kubernetes, Helm, and kubectl providers.

```text
Infrastructure state -> EKS outputs -> Platform state -> Kubernetes API
```

This prevents Terraform from initializing a Kubernetes provider while the
cluster it needs is still being created. Creation and destruction are
therefore ordered by the root deployment scripts, not by `-target` or by a
provider `depends_on`.

A dedicated EKS cluster (`logging-eks`, `eu-west-2`) runs a highly available
Elastic Stack for centralized log collection from Kubernetes workloads. The
stack is deployed via the ECK (Elastic Cloud on Kubernetes) operator rather
than raw Helm charts for the stateful components (Elasticsearch, Kibana),
because ECK automates TLS certificate issuance/rotation, rolling upgrades,
and safe scaling — the operational surface that is hardest to get right by
hand. Filebeat, being stateless, is deployed as a plain Helm chart.

## Why a separate cluster

This capstone is built on its own EKS cluster rather than added to
`tooling-app-eks`. Elasticsearch data nodes are memory/IO-heavy, long-lived,
stateful workloads with very different scaling and maintenance rhythms than
Jenkins/Artifactory/Vault. Isolating them:

- avoids resource contention and noisy-neighbor risk on the tooling cluster
- lets the logging platform's node pools, IAM boundary, and upgrade cadence
  be reasoned about independently
- means an EKS control-plane or node-group issue on one cluster can't take
  down the other

The two clusters still share the same Vault instance (policies scoped by
path, see `vault/`), the same Route 53 hosted zone (`qyonlimited.com`), and
the same Terraform state conventions.

## Component diagram

See `diagrams/architecture.mermaid` for the full diagram. Summary:

```
                              Internet
                                 │
                         ingress-nginx (general pool)
                                 │
                    TLS via cert-manager + Route53 DNS-01
                                 │
                    ┌────────────┴────────────┐
                    │                          │
              Kibana x2                  Order API x3
          (elastic-system ns)          (applications ns)
                    │                          │
                    │                    stdout (JSON logs)
                    │                          │
                    │                   Filebeat DaemonSet
                    │                    (logging ns, every
                    │                     general-pool node)
                    │                          │
                    └──────────► Elasticsearch ◄┘
                                       │
                          ┌────────────┼────────────┐
                     3x master     3x data      SLM → S3
                    (es-master     (es-data     snapshot
                     node pool,     node pool,   bucket
                     no data)       gp3 EBS)     (IAM user, keystore)
```

## Namespace design

| Namespace        | Purpose                                              |
|-------------------|-------------------------------------------------------|
| `elastic-system`  | ECK operator, Elasticsearch CR, Kibana CR             |
| `logging`         | Filebeat DaemonSet                                    |
| `applications`    | Demo Order API                                        |
| `monitoring`      | Reserved for kube-prometheus-stack / Alertmanager if mirrored from tooling-app-eks |
| `vault`           | Vault server + Agent Injector (see "Vault" below)     |

`cert-manager`, `ingress-nginx`, and `external-dns` each get their own
namespace too, created by their respective Helm releases — not listed
here since they're addon-owned rather than part of this project's own
workload boundary design.

Namespaces exist as hard trust boundaries, not just organizational folders —
every namespace has a default-deny `NetworkPolicy` with explicit allows
layered on top, defined natively in Terraform
(`terraform/modules/logging-platform/network-policies.tf`) rather than
applied as separate YAML — see the "Fully Terraform-native" section below
for why.

## Node pools

Three dedicated managed node groups, not one generic pool:

| Pool        | Instance type | Taint                         | Why                                                        |
|-------------|---------------|--------------------------------|-------------------------------------------------------------|
| `es-master` | m6i.large     | `dedicated=es-master:NoSchedule` | Quorum only — small, stable, never competes for CPU/memory with data nodes |
| `es-data`   | r6i.xlarge    | `dedicated=es-data:NoSchedule`   | Memory-optimized; ES is JVM-heap and OS page-cache hungry   |
| `general`   | m6i.large     | none (spot-eligible)            | Kibana, Filebeat, ingress controller, Order API — all tolerate interruption |

Pod anti-affinity spreads master and data StatefulSet pods across AZs
(`topology.kubernetes.io/zone`), so losing one AZ never drops ES below
quorum or below a full replica set.

## Data flow

1. Order API writes structured JSON logs to stdout (never touches
   Elasticsearch or Filebeat directly).
2. Container runtime writes those lines to `/var/log/containers/*.log` on
   the node.
3. Filebeat's Kubernetes autodiscover provider watches for pods annotated
   `co.elastic.logs/enabled: "true"`, harvests their log files, parses the
   JSON in place (no Logstash/grok needed), enriches with Kubernetes
   metadata, and ships to Elasticsearch over TLS.
4. Elasticsearch indexes into the `app-logs` rollover alias, governed by an
   ILM policy (hot → warm → cold → delete).
5. Kibana queries Elasticsearch for dashboards, saved searches, and alerts.
6. SLM (Snapshot Lifecycle Management) snapshots indices nightly to S3,
   using a narrowly-scoped IAM user's static credentials loaded into
   Elasticsearch's keystore — the one deliberate exception to "no static
   AWS credentials" in this stack; see `docs/troubleshooting.md` for why
   Pod Identity (used everywhere else — cert-manager, EBS CSI, Vault)
   isn't viable here specifically.

## Fully Terraform-native — no Kustomize, no manual `kubectl`/`helm`

An earlier version of this project used Kustomize (`kubernetes/base/` +
per-environment overlays) alongside Terraform, with a documented,
ordered sequence of manual `kubectl apply -k` and `helm install` commands
to run after `terraform apply` finished. In practice, that ordering
requirement was exactly what broke on real applies — a StorageClass
applied out of sequence relative to a PVC that needed it, an AWS Load
Balancer Controller nobody had a Terraform resource for at all, a Vault
bootstrap script whose environment exports never survived being run as a
subshell of the walkthrough it was written for. Every one of these was a
"the human ran commands in the wrong order, or the runbook simply didn't
cover a step" failure — not a bug in any individual command.

This version has none of that split. Every Kubernetes resource — from
Namespaces and the StorageClass through the Elasticsearch/Kibana CRs to
NetworkPolicies — is created directly by Terraform, using one of three
mechanisms depending on the resource:

- **Native `kubernetes_*` resources** (`kubernetes_namespace_v1`,
  `kubernetes_deployment_v1`, `kubernetes_service_v1`,
  `kubernetes_storage_class_v1`) for well-modeled, stable core API types.
- **`kubectl_manifest`** (the `alekc/kubectl` provider — an actively
  maintained fork; the original `gavinbunney/kubectl` has had no updates
  in 2+ years) for CRD-backed resources — the Elasticsearch/Kibana CRs,
  cert-manager's `ClusterIssuer`, and the NetworkPolicies. Hashicorp's own
  `kubernetes_manifest` resource explicitly can't create a CRD-dependent
  resource in the same apply as the CRD itself; `kubectl_manifest` does a
  live dry-run apply against the API server instead of static plan-time
  schema validation, which sidesteps that limitation entirely.
- **`helm_release`** for every controller/operator (ALB controller,
  ingress-nginx, cert-manager, external-dns, the ECK operator, Vault) —
  each with explicit `depends_on` wiring so Terraform's own dependency
  graph enforces the ordering a human previously had to remember.

Where the old design needed a person to run commands 1 through N in the
right order, this design needs `terraform apply`.

## Design decisions and trade-offs

- **ECK over raw Helm for ES/Kibana**: more moving parts to learn upfront,
  but far less hand-rolled TLS/cert-rotation/upgrade logic to maintain long
  term. This is the same trade-off reasoning behind using Vault Agent
  injection instead of `kubectl create secret` for the Order API's
  credentials.
- **Filebeat over Logstash**: the Order API already emits structured JSON,
  so there's no parsing/enrichment work that justifies Logstash's extra
  operational weight. Filebeat ships directly to Elasticsearch. If a future
  log source emits unstructured text needing grok patterns, Logstash (or an
  ingest pipeline) can be added without changing the Filebeat DaemonSet.
- **Dedicated master nodes at 3, not 1**: a single master is a classic
  demo-project shortcut and a single point of failure. 3 gives quorum
  (tolerates 1 loss) without the cost of 5.
- **gp3 over gp2 for ES storage**: same baseline IOPS/throughput at lower
  cost, and both are independently tunable without a volume resize later.
- **EKS Pod Identity over IRSA**: no OIDC provider federation, no
  ServiceAccount annotations, simpler trust policies — a genuine
  improvement for cert-manager, the EBS CSI driver, and Vault's own AWS
  access. Deliberately *not* used for Elasticsearch's S3 snapshot access,
  where both federated-identity mechanisms hit real, currently-open
  upstream bugs against the bundled `repository-s3` plugin — see
  `docs/troubleshooting.md` for the incident history.
- **Vault fully Terraform-managed, single replica, KMS auto-unseal**:
  `terraform apply` deploys Vault, initializes it once, and it auto-unseals
  via AWS KMS on every restart from then on — no manual
  `helm install`/`vault operator init`/`vault operator unseal` ever. Raft
  storage supports multi-node HA, but that's genuine additional complexity
  (leader election, join process) intentionally deferred for this
  project's scope; the KMS auto-unseal piece is what actually eliminates
  manual steps, and that's true regardless of replica count.
