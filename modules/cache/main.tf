
# ----------------------------------------------------------------------------------------------------------------------
# global metadata
# ----------------------------------------------------------------------------------------------------------------------

terraform {
  required_version = ">= 0.14"
}

locals {
  cache_name = "gl-${var.name}-cache"

  tags = merge(
    { Name = local.cache_name },
    var.tags,
  )
}

resource "aws_s3_bucket" "_" {
  #checkov:skip=CKV_AWS_18:cache requires no access logs
  #checkov:skip=CKV_AWS_144:cache requires no replication
  #checkov:skip=CKV_AWS_145:AWS default encryption sufficient
  #checkov:skip=CKV_AWS_21:cache requires no versioning

  # avoid name clashes
  bucket_prefix = "${local.cache_name}-"
  tags          = var.tags

  # prevent any public access to bucket
  acl = "private"

  # encryption is as strong as with KMS, but free of KMS charges
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }

  # cache contents are ephemeral by design
  # therefore the bucket and objects do not have to be protected from deletion
  # and contents are cleared regularly

  force_destroy = true

  versioning {
    enabled    = false
    mfa_delete = false
  }

  lifecycle_rule {
    id      = "cache_expiration"
    enabled = true

    abort_incomplete_multipart_upload_days = 1

    expiration {
      days = var.expiration_days
    }

    noncurrent_version_expiration {
      days = 1
    }
  }
}

# block public access to S3 cache bucket
resource "aws_s3_bucket_public_access_block" "build_cache_policy" {

  bucket = aws_s3_bucket._.id

  block_public_acls       = true
  block_public_policy     = true
  restrict_public_buckets = true
  ignore_public_acls      = true
}
