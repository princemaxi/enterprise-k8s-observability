# Terminal Walkthrough: Enterprise Kubernetes Logging Platform

This is the fully-automated build. Nearly everything that used to be a
separate, ordered sequence of manual `kubectl`/`helm`/`vault` commands is
now inside `terraform apply` itself — see `docs/architecture.md` for why,
and `docs/troubleshooting.md` for the real incidents (StorageClass
ordering, a missing load balancer controller, a Vault script whose
exports never survived its own subshell) that made "let a human run
commands in the right order" an unacceptable design.

This walkthrough builds **dev** as the running example — swap `dev` for
`sit`/`prod` throughout for the others. All three are fully independent:
separate `terraform/environments/<env>` directories, separate EKS
clusters, separate everything.

**WSL:** if `terraform apply`/`docker`/`kubectl` hang, check `/etc/wsl.conf`
has `[network] generateResolvConf = false` if you've pinned a custom DNS
resolver, and confirm Docker Desktop's WSL integration is enabled for this
distro (`docker info` should succeed with no errors before you start).

---

## Phase 0 — Prerequisites

```bash
terraform -version && aws --version && kubectl version --client && docker info >/dev/null && k6 version && python3 --version
aws sts get-caller-identity
aws route53 list-hosted-zones-by-name --dns-name qyonlimited.com --query "HostedZones[0].Id" --output text
```
Note the zone ID — you'll put it straight into `terraform.tfvars` in Phase 1, not use it interactively anywhere.

---

## Phase 1 — The whole platform

```bash
cd terraform/environments/dev
cp backend.hcl.example backend.hcl
```
Fill in a real S3 bucket + DynamoDB table (one-time creation commands are
in that file's comments — the same bucket serves all three environments,
one state key each).

```bash
cp terraform.tfvars.example terraform.tfvars
```
Fill in your real `route53_hosted_zone_id` (from Phase 0). Everything
else in that file is optional — dev's defaults already match what's in
`variables.tf`.

```bash
terraform init -backend-config=backend.hcl
```
Expect Terraform to download `terraform-aws-modules/vpc/aws`,
`terraform-aws-modules/eks/aws`, and four providers beyond the base `aws`
one: `helm`, `kubernetes`, `kubectl` (the `alekc/` fork — the original
`gavinbunney/kubectl` is unmaintained), and `docker`. All normal, nothing
vendored except the ALB controller's IAM policy JSON
(`terraform/modules/logging-platform/policies/`) — deliberately not
fetched over the network at apply time.

```bash
terraform plan -out=tfplan
```

**Sense check the plan** — this one apply does far more than
infrastructure now. Expect roughly: 1 VPC, 1 NAT gateway (dev), 1 EKS
cluster (`cluster_version = 1.34`), 3 node groups, the
`eks-pod-identity-agent` addon, 5 Pod Identity associations (cert-manager,
EBS CSI, Vault-KMS, ALB controller, external-dns) with their IAM roles, 1
KMS key + alias, 1 S3 bucket, 1 IAM user + access key (Elasticsearch's
deliberate exception — see the README), 6 Helm releases (ALB controller,
ingress-nginx, cert-manager, external-dns, ECK operator, Vault), several
`null_resource`s (Vault bootstrap, Elasticsearch health-poll, ES
bootstrap), a Docker image build/push, and the Kubernetes-native
resources for Elasticsearch/Kibana/Order API/Ingress/NetworkPolicies. If
the plan is missing whole categories of this, or wants to create dozens
more resources than expected, stop and check you're not pointed at an
existing/wrong state file.

```bash
terraform apply tfplan
```

**25–35 minutes.** Longer than infrastructure alone would take — EKS
control plane + node scale-out is still the largest single chunk, but
Vault's init and Elasticsearch's real health-poll (not just "the CR was
accepted") both add genuine, necessary wait time on top. This is not a
hang; watch the `local-exec` output from `vault_bootstrap`,
`wait_for_elasticsearch`, and `es_bootstrap` scroll past as it progresses
through them in order.

---

## Verify everything came up

```bash
cd ../../..
make ENV=dev status
```

Or by hand:

```bash
$(cd terraform/environments/dev && terraform output -raw configure_kubectl)
kubectl get nodes -L role
```
Expect 3 nodes for dev (1 per role; sit is 7, prod is 9).

```bash
kubectl -n vault get pods
kubectl -n vault get secret vault-init
kubectl -n vault exec vault-0 -- vault status
# Initialized: true, Sealed: false — zero manual steps taken to get here
```

```bash
kubectl -n elastic-system get elasticsearch,kibana
# HEALTH: green on both
```

```bash
kubectl -n applications get pods,ingress
kubectl -n applications get pod -l app=order-api -o jsonpath='{.items[0].spec.containers[*].name}'
# should list: order-api vault-agent
```

```bash
kubectl -n elastic-system get certificate
kubectl -n applications get certificate
# both READY: true (DNS-01 + cert issuance can take a few minutes after
# the apply itself finishes — this is the one thing genuinely still
# propagating asynchronously in the background)
```

DNS is automatic now (external-dns watches every Ingress and manages the
Route53 records itself) — no manual CNAME step. Give it a few minutes
after the apply completes, then:

```bash
curl -k https://kibana.dev.logging.qyonlimited.com/api/status
curl -k https://order-api.dev.logging.qyonlimited.com/health
```

If either isn't resolving yet, check external-dns's own logs rather than
assuming something's broken:
```bash
kubectl -n external-dns logs -l app.kubernetes.io/name=external-dns --tail=50
```

---

## Genuinely manual steps that remain

Two things, both outside what Terraform can reasonably own:

**1. Kibana dashboards** — building the actual visualizations is a UI
task. Bootstrap the index pattern first:
```bash
cd dashboards
export KIBANA_URL=https://kibana.dev.logging.qyonlimited.com
./create-index-pattern.sh
```
Then build the dashboards described in `dashboards/README.md` in the
Kibana UI.

**2. Load test:**
```bash
cd ../scripts
k6 run --env BASE_URL=https://order-api.dev.logging.qyonlimited.com perf-test.js
```
Or: `make ENV=dev perf-test`.

Everything else — infrastructure, every addon, Vault (deployed AND
initialized AND unsealed AND its auth configured), Elasticsearch, Kibana,
ILM/snapshot repo/alerting, Filebeat, the Order API (image built AND
pushed AND deployed), ingress, TLS, DNS, NetworkPolicies — came up from
the single `terraform apply` in Phase 1.

---

## Troubleshooting mid-apply

If `terraform apply` fails partway through, **don't `terraform destroy`
by reflex** — most of the `null_resource` bootstrap scripts
(`vault-bootstrap.sh`, `es-bootstrap.sh`, `wait-for-elasticsearch.sh`) are
fully idempotent specifically so a re-run of `terraform apply` picks up
exactly where it left off rather than needing a clean slate. Read the
actual error first:

```bash
terraform apply tfplan  # just re-run it
```

If it fails at the same step twice in a row, that's a real problem worth
diagnosing rather than retrying a third time — see
`docs/troubleshooting.md` for the specific failure modes this project has
actually hit (StorageClass-before-PVC ordering, a missing load balancer
controller, ECK's S3 credential requirements, and more) and how each was
actually diagnosed, not just patched.

---

## Clean-up

```bash
cd terraform/environments/dev
terraform destroy
```

This tears down everything Terraform created — infrastructure, every
addon, Vault, the KMS key (7-day deletion window), Elasticsearch, the
Order API's ECR images. Check for orphaned EBS volumes after
(`reclaimPolicy: Retain` on `es-gp3`):
```bash
aws ec2 describe-volumes --filters Name=tag:kubernetes.io/cluster/logging-eks-dev,Values=owned
```

---

Every step above also has a `make ENV=dev <target>` equivalent for
verification/troubleshooting — `make help` lists them. The build itself
is `make ENV=dev tf-init tf-plan tf-apply` if you'd rather not type
`terraform` directly.
