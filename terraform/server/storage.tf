# ---------------------------------------------------------------- image files handed to the server
resource "aws_s3_bucket" "releases" {
  bucket = "lims-releases-${local.account_id}"
  lifecycle { prevent_destroy = true }
}

# ---------------------------------------------------------------- off-site backups, in another region
# The server can add to it and nothing else. Object Lock keeps each backup whoever asks.
resource "aws_s3_bucket" "backups" {
  provider            = aws.dr
  bucket              = "lims-backups-${local.account_id}"
  object_lock_enabled = true
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_object_lock_configuration" "backups" {
  provider = aws.dr
  bucket   = aws_s3_bucket.backups.id
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.backup_lock_days
    }
  }
  depends_on = [aws_s3_bucket_versioning.backups]
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  provider = aws.dr
  bucket   = aws_s3_bucket.backups.id
  rule {
    id     = "keep"
    status = "Enabled"
    filter {}
    expiration { days = var.backup_keep_days }
    noncurrent_version_expiration { noncurrent_days = 1 }
    abort_incomplete_multipart_upload { days_after_initiation = 2 }
  }
  depends_on = [aws_s3_bucket_versioning.backups]
}

resource "aws_s3_bucket_versioning" "backups" {
  provider = aws.dr
  bucket   = aws_s3_bucket.backups.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  provider                = aws.dr
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "backups" {
  provider = aws.dr
  bucket   = aws_s3_bucket.backups.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TlsOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket_versioning" "releases" {
  bucket = aws_s3_bucket.releases.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "releases" {
  bucket                  = aws_s3_bucket.releases.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------- hourly copies of the data disk
resource "aws_iam_role" "snapshots" {
  name = "lims-snapshots"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "dlm.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "snapshots" {
  role       = aws_iam_role.snapshots.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "data" {
  description        = "LIMS data disk hourly for a day and daily for a week"
  execution_role_arn = aws_iam_role.snapshots.arn
  state              = "ENABLED"
  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Snapshot = "hourly" }
    schedule {
      name        = "hourly"
      copy_tags   = true
      tags_to_add = { Kind = "hourly" }
      create_rule {
        interval      = 1
        interval_unit = "HOURS"
      }
      retain_rule { count = 24 }
    }
    schedule {
      name        = "daily"
      copy_tags   = true
      tags_to_add = { Kind = "daily" }
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["21:30"] # 03:00 in India, after the nightly backup
      }
      retain_rule { count = 7 }
    }
  }
}
