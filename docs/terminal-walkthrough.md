# Deployment walkthrough

This repository is not a generic standalone ELK stack. It deploys a full EKS-based logging platform for Elasticsearch, Kibana, Filebeat, Vault, ingress, TLS, DNS, and the Order API.

The deployment is deliberately split into two Terraform roots:

1. Infrastructure root creates the AWS and EKS resources.
2. Platform root creates the Kubernetes and Helm resources that depend on the infrastructure outputs.

The live repo layout is:

- `terraform/infrastructure/environments/dev`
- `terraform/platform/environments/dev`
- `deploy-dev.sh`
- `destroy-dev.sh`
- `Makefile`

This separation is intentional and is the reason the workflow differs from older single-root examples.

---

## Phase 0 — Confirm Helm chart versions before deploying

Before any apply, validate the pinned Helm chart versions used by the repo. The current stack in Terraform is:

- Vault: `0.34.1`
- aws-load-balancer-controller: `1.8.1`
- ingress-nginx: `4.15.1`
- cert-manager: `v1.21.1`
- external-dns: `1.21.1`
- ECK operator: `2.14.0`

Run this once from the repo root:

```bash
helm repo add elastic https://helm.elastic.co
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo add eks https://aws.github.io/eks-charts
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm repo update

for c in \
  elastic/eck-operator \
  hashicorp/vault \
  eks/aws-load-balancer-controller \
  ingress-nginx/ingress-nginx \
  jetstack/cert-manager \
  external-dns/external-dns; do
  echo "$c -> $(helm search repo "$c" --versions | sed -n '2p' | awk '{print $2}')"
done
```

If a chart version differs from the repo’s pinned version, update the `version = "..."` in the corresponding Terraform resource before continuing.

---

## Phase 1 — Prerequisites

The repo expects the following tools:

```bash
terraform -version
aws --version
kubectl version --client
docker info >/dev/null
k6 version
python3 --version
```

Also confirm your AWS identity and the hosted zone used for Route53:

```bash
aws sts get-caller-identity
aws route53 list-hosted-zones-by-name --dns-name qyonlimited.com --query "HostedZones[0].Id" --output text
```

You need the hosted zone ID for the `route53_hosted_zone_id` variable. The project defaults the dev domain to:

```text
dev.logging.qyonlimited.com
```

Important notes:

- `python3` is required because the Vault bootstrap script parses the output of `vault operator init`.
- Docker must be available because the `docker` Terraform provider builds and pushes the Order API image.
- The repo assumes the AWS CLI is configured with the correct account and region.
- The project uses the `eks-pod-identity-agent`, ALB controller, cert-manager, and external-dns patterns rather than a generic single-cluster local stack.

---

## Phase 2 — Configure backend and environment settings

From the repo root, copy the real backend files into the repository-root `terraform/` directory because the deployment script reads those generated files directly:

```bash
cp terraform/infrastructure/environments/dev/backend.hcl \
  terraform/backend-dev-infrastructure.hcl

cp terraform/platform/environments/dev/backend.hcl \
  terraform/backend-dev-platform.hcl
```

Do not copy them into the per-environment folders. Edit the two files created in the repo-root `terraform/` directory with your real S3 bucket and DynamoDB lock table values. There are no placeholder backend files left in the live deployment flow.

The repo defaults to this dev setup in the variables file:

- state bucket: `qyon-terraform-state`
- state region: `eu-west-2`
- domain: `dev.logging.qyonlimited.com`

You do not need to edit every variable in `terraform.tfvars`; only values relevant to your environment. The required dev value is the Route53 hosted zone ID.

Edit the live dev tfvars file directly, not a copied template:

```bash
terraform/infrastructure/environments/dev/terraform.tfvars
```

Then update `route53_hosted_zone_id` and any values you want to override for the dev environment. This repo keeps the real environment variables in place and edits only the active configuration files used by the stack.

The current stack uses the shared `qyonlimited.com` Route53 zone and environment-specific subdomains, such as:

- `https://kibana.dev.logging.qyonlimited.com`
- `https://order-api.dev.logging.qyonlimited.com`

---

## Phase 3 — Deploy the whole platform

The safest and most repo-native way to bring everything up is the provided script:

```bash
./deploy-dev.sh
```

This script does the following in order:

1. Initializes the infrastructure root.
2. Plans and applies the AWS/EKS resources.
3. Waits for the EKS cluster to become active.
4. Updates `kubeconfig`.
5. Initializes the platform root.
6. Plans and applies the Kubernetes and Helm resources.
7. Verifies the cluster and basic pod state.

This matches the repo architecture exactly: infrastructure and platform are intentionally separated, and the platform root does not initialize until infrastructure outputs are available.

Promotion flow for real environments:

```bash
# 1. validate in dev
./deploy-dev.sh

# 2. promote the same code and approved Terraform to sit
terraform -chdir=terraform/infrastructure/environments/sit init -backend-config=backend.hcl
terraform -chdir=terraform/infrastructure/environments/sit plan
terraform -chdir=terraform/platform/environments/sit init -backend-config=backend.hcl
terraform -chdir=terraform/platform/environments/sit plan

# 3. after sit passes smoke tests and approval, apply to prod
terraform -chdir=terraform/infrastructure/environments/prod init -backend-config=backend.hcl
terraform -chdir=terraform/infrastructure/environments/prod plan
terraform -chdir=terraform/platform/environments/prod init -backend-config=backend.hcl
terraform -chdir=terraform/platform/environments/prod plan
```

This is the production-friendly pattern: use dev for experimentation, sit for near-production validation, and prod for controlled release with approval gates and state separation.

You can also run the equivalent Terraform targets directly:

```bash
make tf-init ENV=dev
make tf-plan ENV=dev
make tf-apply ENV=dev
```

For validation after apply:

```bash
make ENV=dev status
```

---

## Phase 4 — What this stack actually creates

This repo creates a real EKS cluster with a split node layout:

- `es-master` node group for master-eligible Elasticsearch nodes
- `es-data` node group for data nodes
- `general` node group for Kibana, Filebeat, ingress, Vault, and application workloads

The platform includes:

- ECK operator for Elasticsearch and Kibana custom resources
- Elasticsearch in the `elastic-system` namespace
- Kibana in the same namespace
- Vault in the `vault` namespace
- ingress-nginx in the `ingress-nginx` namespace
- cert-manager in the `cert-manager` namespace
- external-dns in the `external-dns` namespace
- AWS Load Balancer Controller in `kube-system`
- Order API in `applications`
- Filebeat in `logging`
- TLS and Route53 integration through cert-manager and external-dns

This is broader than a bare ELK deployment and is intentionally designed as a real logging platform rather than a toy local stack.

---

## Phase 5 — Verify the deployment

After apply, validate the cluster and major components:

```bash
kubectl get nodes -L role
kubectl get pods -A
kubectl -n elastic-system get elasticsearch,kibana
kubectl -n vault get pods
kubectl -n applications get pods,ingress
kubectl -n elastic-system get certificate
kubectl -n applications get certificate
```

The stack should show:

- EKS nodes are present and labeled by role
- Elasticsearch health is green
- Kibana is running
- Vault is initialized and unsealed
- Application pods and ingress resources exist
- TLS certificates are ready

The repo can also run a scripted health check through the Makefile:

```bash
make ENV=dev status
```

---

## Phase 6 — Accessing the services

Once external-dns propagates and the ingress is live, the URLs should resolve:

```bash
https://kibana.dev.logging.qyonlimited.com
https://order-api.dev.logging.qyonlimited.com
```

You can test the endpoints directly:

```bash
curl -k https://kibana.dev.logging.qyonlimited.com/api/status
curl -k https://order-api.dev.logging.qyonlimited.com/health
```

If DNS is not responding yet, inspect external-dns:

```bash
kubectl -n external-dns logs -l app.kubernetes.io/name=external-dns --tail=50
```

---

## Phase 7 — The only remaining manual steps

The repo automates almost everything. The remaining human tasks are intentionally narrow:

### 1. Kibana dashboards

```bash
cd dashboards
export KIBANA_URL=https://kibana.dev.logging.qyonlimited.com
./create-index-pattern.sh
```

Then build the dashboards in the Kibana UI as described in `dashboards/README.md`.

### 2. Load testing

```bash
cd scripts
k6 run --env BASE_URL=https://order-api.dev.logging.qyonlimited.com perf-test.js
```

Or through the repo target:

```bash
make ENV=dev perf-test
```

Everything else in the platform — EKS, VPC, IAM, ALB controller, ingress, cert-manager, external-dns, Vault, Elasticsearch, Kibana, Filebeat, TLS, DNS, and the Order API deployment — is handled through Terraform and the bootstrap scripts.

---

## Phase 8 — Destroy the environment

To destroy the environment cleanly:

```bash
./destroy-dev.sh
```

Or with Terraform directly:

```bash
make ENV=dev tf-destroy
```

The repo intentionally destroys the platform state before the infrastructure state to avoid contacting a cluster that no longer exists.

---

## Key repo-specific corrections from the older walkthrough

Older guidance was too generic. The current repo differs in several important ways:

- It uses two Terraform roots instead of a single `terraform/environments/dev` path.
- It deploys through `deploy-dev.sh` and `Makefile` targets rather than manually stepping through each Terraform command.
- It installs and manages Vault, ECK, and the ingress stack as Helm-based resources in Terraform.
- It is EKS-first and includes AWS networking, IAM, KMS, Route53, and ALB integration, not just Elasticsearch and Kibana alone.
- The domain pattern is environment-specific under the shared `qyonlimited.com` hosted zone.

These details matter because they define how the stack actually comes up in practice.

---

## Recommended order of operations for a fresh deployment

```bash
# 1. Copy the live backend config files into the repo-root terraform directory
cp terraform/infrastructure/environments/dev/backend.hcl terraform/backend-dev-infrastructure.hcl
cp terraform/platform/environments/dev/backend.hcl terraform/backend-dev-platform.hcl

# 2. Fill in real S3 bucket, lock table, and Route53 zone ID
#    in both backend files and the live dev tfvars file

# 3. Deploy the whole stack
./deploy-dev.sh

# 4. Validate
make ENV=dev status

# 5. Optional: dashboards and load test
cd dashboards && ./create-index-pattern.sh
cd ../scripts && k6 run --env BASE_URL=https://order-api.dev.logging.qyonlimited.com perf-test.js
```

This is the workflow that matches the code in the current stack and the verified repo structure.
