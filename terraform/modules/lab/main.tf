# One company: its file buckets (Mumbai + Hyderabad copy), its settings in SSM, its certificate, the load balancer
# routing for its two addresses, its uptime checks and its alarms. Created once per entry in var.labs.

terraform {
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0", configuration_aliases = [aws.dr, aws.use1] }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

locals {
  tags        = { Lab = var.slug }
  bucket      = "lims-${var.slug}-files-${var.account_id}"
  bucket_dr   = "lims-${var.slug}-files-dr-${var.account_id}"
  api_domain  = "api.${var.domain}"
  ui_port     = 8100 + var.number
  api_port    = 3100 + var.number
  db_name     = "lims_${replace(var.slug, "-", "_")}"
  db_owner    = "lims_${replace(var.slug, "-", "_")}_owner"
  db_app      = "lims_${replace(var.slug, "-", "_")}_app"
  ssm         = "/lims/prod/${var.slug}"
  has_zone    = var.dns_zone_id != null
  storage_url = "https://${local.bucket}.s3.${var.region}.amazonaws.com"
}

# ---------------------------------------------------------------- files: Mumbai bucket
# Object Lock can only be turned on when a bucket is created. No default retention: the app locks issued PDFs.
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
    Statement = [{ Effect = "Allow", Principal = { Service = "s3.amazonaws.com" }, Action = "sts:AssumeRole" }]
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
  port                 = local.ui_port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  deregistration_delay = 30
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
  port                 = local.api_port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  deregistration_delay = 30
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

# ---------------------------------------------------------------- settings in SSM
# Secrets are generated here and kept in the encrypted, access-restricted state. Integration secrets (SMTP password,
# WhatsApp, e-invoicing) are added by hand with aws ssm put-parameter, so they never enter the state.
resource "random_password" "db_owner" {
  length  = 40
  special = false
}

resource "random_password" "db_app" {
  length  = 40
  special = false
}

resource "random_password" "session" {
  length  = 64
  special = false
}

resource "random_password" "setup" {
  length  = 48
  special = false
}

locals {
  secure = {
    DATABASE_URL           = "postgresql://${local.db_app}:${random_password.db_app.result}@${var.rds_address}:5432/${local.db_name}?sslmode=verify-full"
    MIGRATION_DATABASE_URL = "postgresql://${local.db_owner}:${random_password.db_owner.result}@${var.rds_address}:5432/${local.db_name}?sslmode=verify-full"
    DB_OWNER_PASSWORD      = random_password.db_owner.result
    DB_APP_PASSWORD        = random_password.db_app.result
    REDIS_URL              = "rediss://:${var.redis_auth_token}@${var.redis_address}:6379/${var.number}"
    SESSION_SECRET         = random_password.session.result
    # Only used while the lab has no user at all; harmless afterwards.
    SETUP_TOKEN = random_password.setup.result
  }
  plain = {
    DB_NAME             = local.db_name
    DB_OWNER            = local.db_owner
    DB_APP              = local.db_app
    S3_BUCKET           = local.bucket
    S3_REGION           = var.region
    S3_ENDPOINT         = "https://s3.${var.region}.amazonaws.com"
    S3_PUBLIC_ENDPOINT  = "https://s3.${var.region}.amazonaws.com"
    S3_FORCE_PATH_STYLE = "false"
    STORAGE_ORIGIN      = local.storage_url
    FRONTEND_ORIGIN     = "https://${var.domain}"
    PUBLIC_API_URL      = "https://${local.api_domain}"
    API_URL             = "https://${local.api_domain}"
    NODE_ENV            = "production"
    COOKIE_SECURE       = "true"
    LAB_NUMBER          = tostring(var.number)
    UI_PORT             = tostring(local.ui_port)
    API_PORT            = tostring(local.api_port)
    version             = var.image_tag
  }
}

resource "aws_ssm_parameter" "secure" {
  for_each = nonsensitive(toset(keys(local.secure)))
  name     = "${local.ssm}/${each.key}"
  type     = "SecureString"
  value    = local.secure[each.key]
  tags     = local.tags
}

resource "aws_ssm_parameter" "plain" {
  for_each = local.plain
  name     = "${local.ssm}/${each.key}"
  type     = "String"
  value    = each.value
  tags     = local.tags
}

# ---------------------------------------------------------------- logs
resource "aws_cloudwatch_log_group" "app" {
  for_each          = toset(["api", "worker", "ui", "migrate"])
  name              = "${local.ssm}/${each.key}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
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
  alarm_name          = "lims-${var.slug}-${each.key}-healthy-servers"
  alarm_description   = "${var.slug}: fewer than 2 healthy ${each.key} servers for 5 minutes"
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
