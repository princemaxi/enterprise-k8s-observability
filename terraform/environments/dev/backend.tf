# Partial backend configuration — see backend.hcl.example. Each environment
# has its own state file (different `key`), same shared state bucket/lock
# table as prod and sit — one bucket, three keys, so state never collides
# between environments even though they're isolated infrastructure.
terraform {
  backend "s3" {}
}
