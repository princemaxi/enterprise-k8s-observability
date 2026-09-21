# Enterprise Kubernetes Logging Platform

This repository deploys the EKS-based enterprise logging stack, including
Elasticsearch, Kibana, Filebeat, Vault, ingress, TLS, DNS, and the Order API.
Terraform is intentionally split into two state boundaries:

```text
terraform/infrastructure/environments/<env>
        -> EKS and AWS resources
terraform/platform/environments/<env>
        -> Kubernetes and Helm resources
```

The platform root reads EKS connection details from the infrastructure state
with `terraform_remote_state`. It never declares a Kubernetes provider in the
same state that creates EKS, so a clean deployment does not need
`terraform apply -target`.

## Deploy dev

Prerequisites are Terraform >= 1.7, AWS CLI credentials, `kubectl`, Docker,
and an S3 bucket plus DynamoDB lock table for Terraform state. The split-root
workflow expects the real backend files in the environment directories and the
repo-root copies used by the helper scripts:

```bash
cp terraform/infrastructure/environments/dev/backend.hcl \
  terraform/backend-dev-infrastructure.hcl
cp terraform/platform/environments/dev/backend.hcl \
  terraform/backend-dev-platform.hcl
```

The live deployment files are real configuration, not placeholders. Edit the
real files in the environment directories and the generated repo-root copies used
by `deploy-dev.sh` and `destroy-dev.sh` only when you need the script-local
paths.

Then run the complete lifecycle:

```bash
./deploy-dev.sh
```

The script initializes, plans, and applies infrastructure, waits for the EKS
control plane, updates kubeconfig, then initializes and applies the platform.
It ends by checking nodes and all namespaces. It uses no `-target`.

## Destroy dev

```bash
./destroy-dev.sh
```

This destroys the platform state first and the infrastructure state second,
so Kubernetes providers are not asked to contact an EKS cluster that has
already been removed.

## Promotion from dev to sit to prod

Use the environment progression as a controlled release pipeline, not as a
single shared workspace:

1. `dev` is for rapid iteration, debugging, app wiring, and operator training.
2. `sit` is a near-production validation environment. Run the same Terraform
   plan/apply flow, smoke tests, dashboard validation, and change windows as you
   would in production, but with a smaller workload profile.
3. `prod` is the protected operating environment. Only merge code or Terraform
   changes after the same plan has passed in `sit`, and require approval before
   apply.

The production practice is:

- keep `dev` ephemeral and disposable
- promote only tested, versioned changes from `dev` into `sit`
- promote verified, approved changes from `sit` into `prod`
- store backend and tfvars values in the real deployment account, not in git
- require code review, CI validation, and a planned change window for all prod
  changes
- use separate state keys and environment-specific domain names for each tier

## Environments and layout

The same two-root layout exists for `dev`, `sit`, and `prod`:

```text
terraform/
├── modules/
│   ├── infrastructure/       # VPC, EKS, addons, IAM, S3, KMS, ECR
│   └── logging-platform/     # Kubernetes resources and Helm releases
├── infrastructure/environments/
│   ├── dev/
│   ├── sit/
│   └── prod/
└── platform/environments/
    ├── dev/
    ├── sit/
    └── prod/
```

Infrastructure state keys are:

```text
enterprise-k8s-logging/<env>/infrastructure/terraform.tfstate
enterprise-k8s-logging/<env>/platform/terraform.tfstate
```

The existing VPC, EKS version, node groups, IAM, ECR, S3, KMS, Route 53,
Elastic, Vault, TLS, DNS, ingress, monitoring, and application settings are
preserved in the split modules.

## Existing-state migration

This refactor does not automatically move a deployed single-state workspace.
Before applying either new root to an existing environment, back up the old
state and use `terraform state mv` to move AWS addresses into the
infrastructure state and Kubernetes/Helm addresses into the platform state.
The exact address list must be generated from the actual state. The old root is not part of this checkout. It must be checked out from the
pre-split commit in a separate worktree (or accessed through an existing
working directory) while the migration is performed:

```bash
terraform -chdir=/path/to/pre-split-worktree/terraform/environments/dev state list
terraform -chdir=/path/to/pre-split-worktree/terraform/environments/dev state pull > dev-single-state-backup.json
```

Initialize both destination roots with their real backend configuration, then
move the state addresses below. The destination address matters because the
root module wrapper changed from `logging_platform` to `infrastructure`:

```bash
terraform -chdir=terraform/infrastructure/environments/dev state mv \
  -state=dev-single-state.tfstate -state-out=dev-infrastructure.tfstate \
  'module.logging_platform.module.vpc' 'module.infrastructure.module.vpc'
terraform -chdir=terraform/infrastructure/environments/dev state mv \
  -state=dev-single-state.tfstate -state-out=dev-infrastructure.tfstate \
  'module.logging_platform.module.eks' 'module.infrastructure.module.eks'
terraform -chdir=terraform/infrastructure/environments/dev state mv \
  -state=dev-single-state.tfstate -state-out=dev-infrastructure.tfstate \
  'module.logging_platform.aws_s3_bucket.es_snapshots' \
  'module.infrastructure.aws_s3_bucket.es_snapshots'
terraform -chdir=terraform/platform/environments/dev state mv \
  -state=dev-single-state.tfstate -state-out=dev-platform.tfstate \
  'module.logging_platform.kubernetes_namespace_v1.logging' \
  'module.logging_platform.kubernetes_namespace_v1.logging'
```

Repeat the same explicit `state mv` form for every address returned by
`terraform state list`: VPC/EKS/IAM/S3/KMS/ECR/Pod Identity addresses go to
infrastructure with the `module.logging_platform` to
`module.infrastructure` prefix change; Kubernetes, Helm, kubectl, and
`null_resource` platform addresses go to platform and retain the
`module.logging_platform` prefix. Include every S3 subresource and managed
IAM/Pod Identity address. Do not guess addresses or run a destination apply
until `terraform plan` shows no unintended creates. If a state is remote,
perform the moves with the backend configured for each destination and retain
the state backup.
The old `terraform/environments` roots are intentionally no longer
deployable and are not present as active configuration here; retain a
pre-split checkout until any legacy state migration has been completed.

See [docs/architecture.md](docs/architecture.md),
[docs/terminal-walkthrough.md](docs/terminal-walkthrough.md), and
[docs/troubleshooting.md](docs/troubleshooting.md) for operational detail.
