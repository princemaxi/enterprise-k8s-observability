# Partial backend configuration — deliberately incomplete. Bucket/table
# names differ per person running this (or per environment if this
# structure grows beyond prod), so they're supplied at `terraform init`
# time rather than hardcoded here:
#
#   terraform init -backend-config=backend.hcl
#
# Copy backend.hcl.example -> backend.hcl, fill in your own state bucket
# and DynamoDB lock table (backend.hcl is gitignored — never commit real
# backend config, since the bucket name alone isn't sensitive but the
# pattern of always gitignoring it prevents mistakes later).
terraform {
  backend "s3" {}
}
