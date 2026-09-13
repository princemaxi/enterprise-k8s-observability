# Enterprise Kubernetes Logging Platform (ELK/Elastic Stack Capstone)

A production-grade, highly available centralized logging platform for
Kubernetes — VPC, EKS, every controller/operator it needs, Vault, the full
Elastic Stack, and a demo Order API — brought up entirely by `terraform
apply`. No separate `kubectl apply`, `helm install`, or manual bootstrap
script. That is a deliberate, hard-won design constraint, not a marketing
line — see `docs/architecture.md` for what this project looked like before
that constraint was enforced, and `docs/troubleshooting.md` for the real
incidents that drove it.

Read `docs/architecture.md` first for the design reasoning. This README is
the build order. For exact commands with expected output at each step, see
`docs/terminal-walkthrough.md`.

## What one `terraform apply` actually does

In dependency order, automatically, no manual step in between any of these:

1. VPC, EKS cluster, 3 managed node groups (`es-master`, `es-data`, `general`)
2. EKS Pod Identity Agent addon, plus Pod Identity associations for every
   AWS-facing workload *except* Elasticsearch's S3 access (see the note
   below)
3. AWS Load Balancer Controller, ingress-nginx, cert-manager, external-dns,
   the ECK operator — all as Terraform-managed Helm releases
4. Vault — deployed, initialized exactly once, KMS-auto-unsealed, its
   Kubernetes auth method configured, and the Order API's secret populated
   — via `kubectl exec`, not a local Vault CLI or port-forward
5. Elasticsearch and Kibana — applied as native custom resources, gated
   behind a real cluster-health poll (not just "the API accepted my
   request")
6. ILM policy, index template, the S3 snapshot repository, SLM, and the
   high-error-rate Watcher alert — bootstrapped automatically once
   Elasticsearch is confirmed healthy
7. Filebeat — its Elasticsearch credentials copied automatically from
   ECK's own auto-generated secrets, no manual `kubectl create secret`
8. The Order API's container image — built and pushed to ECR by Terraform
   itself (`kreuzwerker/docker` provider), then deployed
9. Ingress + TLS (cert-manager, DNS-01) and NetworkPolicies

## Why Elasticsearch's S3 access is the one exception

Every other AWS-facing workload here uses EKS Pod Identity — no OIDC
federation, no ServiceAccount annotations. Elasticsearch's S3 snapshot
access deliberately does **not**: both IRSA and Pod Identity were tried,
and both hit real, currently-open upstream bugs specific to Elasticsearch's
bundled `repository-s3` plugin. A narrowly-scoped IAM user, loaded into
Elasticsearch's own keystore, is Elastic's own documented fallback for
exactly this situation — see `docs/troubleshooting.md` for the incident
history and the specific GitHub issues, if you're ever tempted to
"simplify" this back to federated identity.

## Environments

dev, sit, and prod are **fully separate EKS clusters** — own VPC, own
control plane, own Elasticsearch, own Vault — not shared namespaces in one
cluster. They share a single Terraform module
(`terraform/modules/logging-platform`); each environment is a thin wrapper
passing in its own sizing.

| | dev | sit | prod |
|---|---|---|---|
| Purpose | Functional correctness | HA/failover validation | Real traffic |
| ES topology | 1 master, 1 data | 3 master (full quorum), 2 data | 3 master, 3 data |
| Instance types | r6i.large / t3.medium | r6i.large / m6i.large | r6i.xlarge / m6i.large |
| NAT gateways | 1 shared | 1 shared | 1 per AZ |
| Order API replicas | 1 | 2 | 3 |
| Snapshot retention | 7 days | 14 days | 90 days |
| Domain | `*.dev.logging.qyonlimited.com` | `*.sit.logging.qyonlimited.com` | `*.logging.qyonlimited.com` |

Every command below takes an environment (`terraform/environments/<env>`,
or `make ENV=<env>`, defaults to `dev`). **`ENV` never defaults to
`prod`** — you always have to say so explicitly.

## Prerequisites

- AWS CLI configured with permissions to create VPC/EKS/IAM/KMS/ECR/S3
  resources
- `terraform` >= 1.7, `kubectl` (for verification/troubleshooting only —
  never required for the apply itself), `k6` (for load testing), `python3`
  (used by `scripts/vault-bootstrap.sh` to parse `vault operator init`'s
  JSON output — runs locally, not inside any pod)
- Docker Engine running locally — Terraform's `docker` provider talks to
  your local Docker daemon the same way `docker build` does, to build and
  push the Order API image
- A Route 53 hosted zone for `qyonlimited.com` — its DNS-01 solver and
  external-dns both operate at the zone level, so `dev.`/`sit.`
  subdomains need no per-environment DNS setup
- An S3 bucket + DynamoDB table for Terraform remote state (see
  `terraform/environments/dev/backend.hcl.example`) — one bucket holds all
  three environments' state, each at its own key

## Build order (repeat per environment)

```bash
cd terraform/environments/dev
cp backend.hcl.example backend.hcl   # fill in your real state bucket/table
cp terraform.tfvars.example terraform.tfvars   # fill in your real route53_hosted_zone_id

terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
```

That's the whole build. Expect 25–35 minutes — EKS control plane and node
group provisioning are the largest chunks, with Vault's init and
Elasticsearch's health-poll gate adding real (necessary) wait time on top.

Verify everything came up:

```bash
cd ../../..
make ENV=dev status
```

Or manually:
```bash
$(cd terraform/environments/dev && terraform output -raw configure_kubectl)
kubectl get nodes -L role
kubectl -n elastic-system get elasticsearch,kibana
kubectl -n vault get pods
kubectl -n applications get pods,ingress
```

DNS is automatic (external-dns watches every Ingress), but propagation and
cert issuance both take a few minutes after the apply finishes:

```bash
curl -k https://kibana.dev.logging.qyonlimited.com/api/status
curl -k https://order-api.dev.logging.qyonlimited.com/health
```

Load test:
```bash
make ENV=dev perf-test
```

Full command-by-command detail, expected output at each stage, and what
to check if a step is slower or different than expected: see
`docs/terminal-walkthrough.md`.

## Repository layout

```
enterprise-k8s-logging/
├── Makefile                    # terraform apply is the platform; everything here is verification/troubleshooting only
├── .github/workflows/          # terraform-ci.yml (fmt/validate/tflint/xref-check/shellcheck, matrix across all 3 envs)
├── terraform/
│   ├── modules/
│   │   └── logging-platform/     # the entire platform — VPC, EKS, addons, Vault, ES/Kibana, Order API, ingress, network policies
│   │       ├── scripts/             # vault-bootstrap.sh, es-bootstrap.sh(+remote), wait-for-elasticsearch.sh — all idempotent, all invoked by null_resource local-exec
│   │       ├── templates/            # elasticsearch.yaml.tpl, kibana.yaml.tpl — one template per environment's sizing, not separate Kustomize patch files
│   │       └── policies/              # vendored IAM policy JSON (ALB controller) — not fetched over the network at apply time
│   └── environments/
│       ├── dev/                  # thin wrapper: dev-sized variables + backend
│       ├── sit/                   # thin wrapper: sit-sized variables + backend
│       └── prod/                   # thin wrapper: prod-sized variables + backend
├── app/                           # Order API source (Flask), Dockerfile — built by Terraform, not by hand
├── vault/                          # vault-agent-annotations.yaml (reference only — the real thing lives in order-api.tf)
├── dashboards/                      # Kibana index pattern bootstrap + dashboard spec (still a manual UI step — see docs/terminal-walkthrough.md)
├── scripts/                          # perf-test.js (k6), tf-xref-check.py (CI + local Terraform validation)
├── diagrams/                          # architecture.mermaid
└── docs/
    ├── architecture.md
    ├── capacity-planning.md
    ├── security.md
    ├── maintenance.md
    ├── troubleshooting.md
    ├── cost-analysis.md
    └── terminal-walkthrough.md
```

## Deliverables checklist (against the project brief)

- [x] Architecture documentation — `docs/architecture.md`, `diagrams/architecture.mermaid`
- [x] Infrastructure as Code — one Terraform module, zero separate `kubectl`/`helm` steps
- [x] Application logging — `app/app.py` (structured JSON, 5 log levels, trace IDs)
- [x] Performance test — `scripts/perf-test.js`
- [x] Security — `docs/security.md`, native NetworkPolicies, Pod Identity, KMS-backed Vault auto-unseal
- [x] Maintenance documentation — `docs/maintenance.md`
- [x] Cost analysis — `docs/cost-analysis.md`
- [x] Troubleshooting guide — `docs/troubleshooting.md`
- [x] CI (lint/validate) — `.github/workflows/terraform-ci.yml`
- [x] Multi-environment (dev/sit/prod) — this section
- [x] Fully automated single-command bring-up — this section, and the reasoning in `docs/architecture.md`
