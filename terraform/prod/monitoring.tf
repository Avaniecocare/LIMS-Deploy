# Step 9: alarms. Everything notifies lims-oncall (email here; add SMS or a paging service on the topic by hand).
# Route 53 health checks report only to us-east-1, so their alarms use a second topic there. Per-company alarms
# (health checks, healthy pods, errors, replication) are in the lab module.

resource "aws_sns_topic" "oncall" {
  name = "lims-oncall"
}

resource "aws_sns_topic" "oncall_use1" {
  provider = aws.use1
  name     = "lims-oncall"
}

resource "aws_sns_topic_subscription" "oncall" {
  for_each  = toset(var.oncall_emails)
  topic_arn = aws_sns_topic.oncall.arn
  protocol  = "email"
  endpoint  = each.key
}

resource "aws_sns_topic_subscription" "oncall_use1" {
  for_each  = toset(var.oncall_emails)
  provider  = aws.use1
  topic_arn = aws_sns_topic.oncall_use1.arn
  protocol  = "email"
  endpoint  = each.key
}

# EventBridge may publish events (failovers, failed backups) to the topic.
resource "aws_sns_topic_policy" "oncall" {
  arn = aws_sns_topic.oncall.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Events"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.oncall.arn
      },
      {
        Sid       = "Alarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.oncall.arn
      },
    ]
  })
}

locals {
  alarm = { actions = [aws_sns_topic.oncall.arn] }
}

# ---------------------------------------------------------------- database and cache
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "lims-rds-cpu"
  alarm_description   = "Database CPU above 80% for 15 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm.actions
  ok_actions          = local.alarm.actions
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "lims-rds-free-storage"
  alarm_description   = "Database free storage below 10 GB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10 * 1024 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  alarm_actions       = local.alarm.actions
  ok_actions          = local.alarm.actions
}

resource "aws_cloudwatch_metric_alarm" "rds_memory" {
  alarm_name          = "lims-rds-free-memory"
  alarm_description   = "Database free memory below 128 MB for 15 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 128 * 1024 * 1024
  comparison_operator = "LessThanThreshold"
  alarm_actions       = local.alarm.actions
  ok_actions          = local.alarm.actions
}

# Each API and worker copy holds up to 13.
resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "lims-rds-connections"
  alarm_description   = "More database connections than expected: check the number of pods before they run out"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.rds_connection_alarm
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm.actions
  ok_actions          = local.alarm.actions
}

# The load balancer itself failing to reach anything: pods gone, or the cluster unreachable.
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "lims-load-balancer-5xx"
  alarm_description   = "The load balancer answered more than 20 requests itself with an error in 5 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.main.arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 20
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm.actions
  ok_actions          = local.alarm.actions
}

# A backup that silently stops is found only when it is needed.
resource "aws_cloudwatch_metric_alarm" "backup_missing" {
  alarm_name          = "lims-backup-missing"
  alarm_description   = "No backup has completed for a day"
  namespace           = "AWS/Backup"
  metric_name         = "NumberOfBackupJobsCompleted"
  dimensions          = { BackupVaultName = aws_backup_vault.prod.name }
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm.actions
  ok_actions          = local.alarm.actions
}

resource "aws_cloudwatch_event_rule" "rds_failover" {
  name        = "lims-rds-failover"
  description = "The database failed over to its standby"
  event_pattern = jsonencode({
    source        = ["aws.rds"]
    "detail-type" = ["RDS DB Instance Event"]
    detail        = { SourceIdentifier = [aws_db_instance.main.identifier], EventCategories = ["failover"] }
  })
}

resource "aws_cloudwatch_event_target" "rds_failover" {
  rule = aws_cloudwatch_event_rule.rds_failover.name
  arn  = aws_sns_topic.oncall.arn
}

# ---------------------------------------------------------------- backups
resource "aws_cloudwatch_event_rule" "backup_failed" {
  name        = "lims-backup-failed"
  description = "A backup or cross-region copy job failed"
  event_pattern = jsonencode({
    source        = ["aws.backup"]
    "detail-type" = ["Backup Job State Change", "Copy Job State Change"]
    detail        = { state = ["FAILED", "ABORTED", "EXPIRED"] }
  })
}

resource "aws_cloudwatch_event_target" "backup_failed" {
  rule = aws_cloudwatch_event_rule.backup_failed.name
  arn  = aws_sns_topic.oncall.arn
}
