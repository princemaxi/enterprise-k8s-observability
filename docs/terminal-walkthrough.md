# Deployment walkthrough

The deployment boundary is deliberate:

1. Infrastructure Terraform creates the VPC, EKS, node groups, addons, IAM,
   ECR, S3, KMS, and other AWS resources.
2. The deployment script waits for EKS to become active and configures
   kubeconfig.
3. Platform Terraform reads the infrastructure outputs and creates the
   Kubernetes and Helm resources.

The two roots have separate S3 keys. The platform root is never initialized
until infrastructure has successfully written its outputs.

## First deployment

```bash
cp terraform/infrastructure/environments/dev/backend.hcl.example \
  terraform/backend-dev-infrastructure.hcl
cp terraform/platform/environments/dev/backend.hcl.example \
  terraform/backend-dev-platform.hcl
# edit both files with the real state bucket and lock table
./deploy-dev.sh
```

The script fails immediately if backend configuration is missing,
infrastructure apply fails, EKS does not become active, or the cluster cannot
be queried. It does not use `terraform apply -target`.

## Verification

```bash
kubectl get nodes -L role
kubectl get pods -A
kubectl -n elastic-system get elasticsearch,kibana
kubectl -n vault get pods
kubectl -n applications get pods,ingress
```

## Destroy

```bash
./destroy-dev.sh
```

Platform destroy runs first, followed by infrastructure destroy. If a
platform destroy is interrupted, fix that platform state while EKS still
exists and rerun it; do not destroy EKS first.

## Existing environments

Back up the old single state, inspect its addresses, and migrate resources
into the two destination states before applying them. Do not use a guessed
`-target` list as a migration strategy. The migration procedure and example
commands are in the repository README.
