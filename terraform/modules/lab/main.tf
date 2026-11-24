# One company: its file buckets (Mumbai + Hyderabad copy), its secrets, its pods' identity, the load balancer routing for
# its two addresses, its uptime checks and its alarms. Created once per entry in var.labs.

terraform {
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0", configuration_aliases = [aws.dr, aws.use1] }
    random = { source = "hashicorp/random", version = "~> 3.7" }
  }
}

locals {
  tags        = { Lab = var.slug }
  bucket      = "lims-${var.slug}-files-${var.account_id}"
  bucket_dr   = "lims-${var.slug}-files-dr-${var.account_id}"
  api_domain  = "api.${var.domain}"
  db_name     = "lims_${replace(var.slug, "-", "_")}"
  db_owner    = "lims_${replace(var.slug, "-", "_")}_owner"
  db_app      = "lims_${replace(var.slug, "-", "_")}_app"
  secret      = "lims/prod/${var.slug}"
  namespace   = "lims-${var.slug}"
  has_zone    = var.dns_zone_id != null
  storage_url = "https://${local.bucket}.s3.${var.region}.amazonaws.com"
}

# ---------------------------------------------------------------- files: Mumbai bucket
# Object Lock can only be turned on when a bucket is created. No default retention: versions are
# kept instead, because the app replaces nothing and deletes nothing, and it may not delete versions.
resource "aws_s3_bucket" "files" {
  bucket              = local.bucket
  object_lock_enabled = true
  tags                = local.tags
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "files" {
  bucket = aws_s3_bucket.files.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "files" {
  bucket                  = aws_s3_bucket.files.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "files" {
  bucket = aws_s3_bucket.files.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "files" {
  bucket = aws_s3_bucket.files.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_policy" "files" {
  bucket = aws_s3_bucket.files.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TlsOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.files.arn, "${aws_s3_bucket.files.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.files]
}

resource "aws_s3_bucket_lifecycle_configuration" "files" {
  bucket = aws_s3_bucket.files.id
  rule {
    id     = "old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER_IR"
    }
    # Locked versions stay until their lock ends, whatever this says.
    noncurrent_version_expiration { noncurrent_days = 365 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
  # The app removes its data exports after a week; this is for any it could not.
  rule {
    id     = "data-exports"
    status = "Enabled"
    filter { prefix = "exports/" }
    expiration { days = 10 }
    noncurrent_version_expiration { noncurrent_days = 1 }
  }
  depends_on = [aws_s3_bucket_versioning.files]
}

# ---------------------------------------------------------------- files: Hyderabad copy
resource "aws_s3_bucket" "files_dr" {
  provider            = aws.dr
  bucket              = local.bucket_dr
  object_lock_enabled = true
  tags                = local.tags
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "files_dr" {
  provider = aws.dr
  bucket   = aws_s3_bucket.files_dr.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "files_dr" {
  provider                = aws.dr
  bucket                  = aws_s3_bucket.files_dr.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "files_dr" {
  provider = aws.dr
  bucket   = aws_s3_bucket.files_dr.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "files_dr" {
  provider = aws.dr
  bucket   = aws_s3_bucket.files_dr.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "files_dr" {
  provider = aws.dr
  bucket   = aws_s3_bucket.files_dr.id
  rule {
    id     = "old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 365 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
  depends_on = [aws_s3_bucket_versioning.files_dr]
}

# ---------------------------------------------------------------- replication Mumbai -> Hyderabad
resource "aws_iam_role" "replication" {
  name = "lims-${var.slug}-replication"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "s3.amazonaws.com" }, Action = "sts:AssumeRole", Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } } }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "replication" {
  role = aws_iam_role.replication.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetReplicationConfiguration", "s3:ListBucket"], Resource = aws_s3_bucket.files.arn },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging", "s3:GetObjectRetention", "s3:GetObjectLegalHold"]
        Resource = "${aws_s3_bucket.files.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateTags", "s3:ObjectOwnerOverrideToBucketOwner"]
        Resource = "${aws_s3_bucket.files_dr.arn}/*"
      },
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "files" {
  bucket = aws_s3_bucket.files.id
  role   = aws_iam_role.replication.arn
  rule {
    id     = "to-hyderabad"
    status = "Enabled"
    filter {}
    # A delete in Mumbai must not delete the disaster copy.
    delete_marker_replication { status = "Disabled" }
    destination {
      bucket        = aws_s3_bucket.files_dr.arn
      storage_class = "STANDARD_IA"
      metrics { status = "Enabled" }
    }
  }
  depends_on = [aws_s3_bucket_versioning.files, aws_s3_bucket_versioning.files_dr]
}

# ---------------------------------------------------------------- routing
resource "aws_lb_target_group" "ui" {
  name                 = "lims-${var.slug}-ui"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip" # pods, kept up to date by a TargetGroupBinding
  vpc_id               = var.vpc_id
  deregistration_delay = 20
  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  tags = local.tags
}

resource "aws_lb_target_group" "api" {
  name                 = "lims-${var.slug}-api"
  port                 = 3000
  protocol             = "HTTP"
  target_type          = "ip" # pods, kept up to date by a TargetGroupBinding
  vpc_id               = var.vpc_id
  deregistration_delay = 20
  health_check {
    path                = "/health/ready"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  tags = local.tags
}

resource "aws_lb_listener_rule" "ui" {
  listener_arn = var.listener_arn
  priority     = var.number * 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui.arn
  }
  condition {
    host_header { values = [var.domain] }
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = var.listener_arn
  priority     = var.number * 10 + 1
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
  condition {
    host_header { values = [local.api_domain] }
  }
}

resource "aws_lb_listener_certificate" "main" {
  count           = var.is_default_certificate ? 0 : 1
  listener_arn    = var.listener_arn
  certificate_arn = var.certificate_arn
}

resource "aws_route53_record" "app" {
  for_each = local.has_zone ? toset([var.domain, local.api_domain]) : toset([])
  zone_id  = var.dns_zone_id
  name     = each.key
  type     = "A"
  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# ---------------------------------------------------------------- what its pods may do in AWS
resource "aws_iam_role" "pods" {
  name               = "lims-${var.slug}-pods"
  assume_role_policy = var.pod_identity_trust
  tags               = local.tags
}

# Its own files, and no deleting: versions and the Hyderabad copy are the backup.
resource "aws_iam_role_policy" "pods" {
  role = aws_iam_role.pods.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"], Resource = "${aws_s3_bucket.files.arn}/*" },
      # Copies of everything, made on request and kept a week.
      { Effect = "Allow", Action = "s3:DeleteObject", Resource = "${aws_s3_bucket.files.arn}/exports/*" },
      { Effect = "Allow", Action = "s3:ListBucket", Resource = aws_s3_bucket.files.arn },
    ]
  })
}

resource "aws_eks_pod_identity_association" "pods" {
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "lims"
  role_arn        = aws_iam_role.pods.arn
  tags            = local.tags
}

# ---------------------------------------------------------------- secrets
# Made once, written straight to Secrets Manager and never kept in the state (ephemeral values, write-only arguments).
# Raising secrets_version makes new ones: the database roles' passwords must be changed with it.
ephemeral "random_password" "this" {
  for_each = toset(["db_owner", "db_app", "session", "setup", "redis"])
  length   = 48
  special  = false
}

locals {
  db_url = "@${var.rds_address}:5432/${local.db_name}?sslmode=verify-full"
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${local.secret}/app"
  description             = "${var.slug}: what its app reads. Add SMTP, WhatsApp, e-invoicing, AI and LICENCE values here by hand."
  recovery_window_in_days = 30
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string_wo = jsonencode({
    DATABASE_URL   = "postgresql://${local.db_app}:${ephemeral.random_password.this["db_app"].result}${local.db_url}"
    REDIS_PASSWORD = ephemeral.random_password.this["redis"].result
    REDIS_URL      = "redis://:${ephemeral.random_password.this["redis"].result}@redis:6379/0"
    SESSION_SECRET = ephemeral.random_password.this["session"].result
    # Only used while the company has no user at all; harmless afterwards.
    SETUP_TOKEN = ephemeral.random_password.this["setup"].result
  })
  secret_string_wo_version = var.secrets_version
}

# The table owner, for migrations only.
resource "aws_secretsmanager_secret" "migrate" {
  name                    = "${local.secret}/migrate"
  description             = "${var.slug}: the database owner, for the migrate Job alone"
  recovery_window_in_days = 30
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "migrate" {
  secret_id                = aws_secretsmanager_secret.migrate.id
  secret_string_wo         = jsonencode({ MIGRATION_DATABASE_URL = "postgresql://${local.db_owner}:${ephemeral.random_password.this["db_owner"].result}${local.db_url}" })
  secret_string_wo_version = var.secrets_version
}

# ---------------------------------------------------------------- uptime checks (Route 53, from several regions)
resource "aws_route53_health_check" "site" {
  for_each          = { ui = [var.domain, "/healthz"], api = [local.api_domain, "/health/ready"] }
  type              = "HTTPS"
  fqdn              = each.value[0]
  port              = 443
  resource_path     = each.value[1]
  request_interval  = 30
  failure_threshold = 2
  regions           = ["ap-southeast-1", "eu-west-1", "us-east-1"]
  tags              = merge(local.tags, { Name = "lims-${var.slug}-${each.key}" })
}

resource "aws_cloudwatch_metric_alarm" "site_down" {
  for_each            = aws_route53_health_check.site
  provider            = aws.use1
  alarm_name          = "lims-${var.slug}-${each.key}-down"
  alarm_description   = "${var.slug}: ${each.key} health check failing from outside"
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = each.value.id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [var.alarm_topic_use1_arn]
  ok_actions          = [var.alarm_topic_use1_arn]
}

# ---------------------------------------------------------------- alarms
resource "aws_cloudwatch_metric_alarm" "healthy" {
  for_each            = { ui = aws_lb_target_group.ui, api = aws_lb_target_group.api }
  alarm_name          = "lims-${var.slug}-${each.key}-healthy-pods"
  alarm_description   = "${var.slug}: fewer than 2 healthy ${each.key} pods for 5 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { TargetGroup = each.value.arn_suffix, LoadBalancer = var.alb_arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 2
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "lims-${var.slug}-api-5xx"
  alarm_description   = "${var.slug}: more than 1% of API requests failing for 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 1
  evaluation_periods  = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]

  metric_query {
    id          = "rate"
    expression  = "IF(requests > 20, 100 * errors / requests, 0)"
    label       = "5xx %"
    return_data = true
  }
  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { TargetGroup = aws_lb_target_group.api.arn_suffix, LoadBalancer = var.alb_arn_suffix }
      stat        = "Sum"
      period      = 60
    }
  }
  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { TargetGroup = aws_lb_target_group.api.arn_suffix, LoadBalancer = var.alb_arn_suffix }
      stat        = "Sum"
      period      = 60
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "replication" {
  alarm_name          = "lims-${var.slug}-replication-failing"
  alarm_description   = "${var.slug}: files failing to copy to Hyderabad"
  namespace           = "AWS/S3"
  metric_name         = "OperationsFailedReplication"
  dimensions          = { SourceBucket = local.bucket, DestinationBucket = local.bucket_dr, RuleId = "to-hyderabad" }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}
