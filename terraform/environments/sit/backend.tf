# Partial backend configuration — see backend.hcl.example. Same shared
# state bucket/lock table as dev and prod, own `key` path.
terraform {
  backend "s3" {}
}
