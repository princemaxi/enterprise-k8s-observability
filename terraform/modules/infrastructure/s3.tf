# S3 bucket for Elasticsearch snapshots (SLM repository target)
resource "aws_s3_bucket" "es_snapshots" {
  bucket = var.snapshot_bucket_name
}

resource "aws_s3_bucket_versioning" "es_snapshots" {
  bucket = aws_s3_bucket.es_snapshots.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "es_snapshots" {
  bucket = aws_s3_bucket.es_snapshots.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "es_snapshots" {
  bucket                  = aws_s3_bucket.es_snapshots.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "es_snapshots" {
  bucket = aws_s3_bucket.es_snapshots.id
  rule {
    id     = "expire-old-snapshots"
    status = "Enabled"
    # Required by the AWS provider even to mean "apply to every object,
    # no prefix/tag restriction" — omitting it is accepted today with a
    # deprecation warning but becomes a hard `plan` failure in a future
    # provider version.
    filter {}
    expiration {
      days = var.snapshot_retention_days
    }
  }
}

# --- Elasticsearch's S3 snapshot credentials ---------------------------
#
# Deliberately a plain IAM user + access key here, NOT IRSA and NOT EKS
# Pod Identity, even though every other AWS-facing workload in this
# module uses Pod Identity (see pod-identity.tf). This isn't an
# oversight — both federated-identity mechanisms have open, unresolved
# upstream bugs specifically against Elasticsearch's bundled repository-s3
# plugin as of ES 8.15.0:
#
#   - IRSA: repository-s3 requires an actual filesystem symlink at
#     config/repository-s3/aws-web-identity-token-file (checks
#     Files.isSymbolicLink(), not just file existence) — undocumented
#     outside Elastic's own IRSA guide, easy to get wrong even when
#     followed exactly.
#   - EKS Pod Identity: ES's bundled AWS SDK v1 predates Pod Identity
#     support (added in SDK v2 2.21.30+), so the credential URI Pod
#     Identity injects gets rejected as an "invalid host" — see
#     elastic/cloud-on-k8s#8320 (open, unresolved as of when this was
#     written).
#
# A narrowly-scoped IAM user — access to nothing but this one bucket —
# loaded into Elasticsearch's own keystore (spec.secureSettings on the
# Elasticsearch CR) is Elastic's own documented fallback for exactly this
# situation, and has no equivalent open bugs. See docs/troubleshooting.md
# for the full incident history if you're ever tempted to "simplify" this
# back to federated identity.
