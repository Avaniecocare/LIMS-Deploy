# Step 9: alarms. Everything notifies lims-oncall (email here; add SMS or a paging service on the topic by hand).
# Route 53 health checks report only to us-east-1, so their alarms use a second topic there. Per-company alarms
# (health checks, healthy servers, errors, replication) are in the lab module.

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

resource "aws_cloudwatch_metric_alarm" "cache_memory" {
  # The replication group's two members are always named <group>-001 and <group>-002.
  for_each            = toset(["lims-cache-001", "lims-cache-002"])
  alarm_name          = "lims-cache-memory-${each.key}"
  alarm_description   = "Cache memory above 80% (the job queue never evicts, so a full cache stops new jobs)"
  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  dimensions          = { CacheClusterId = each.key }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
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

resource "aws_cloudwatch_event_rule" "cache_failover" {
  name        = "lims-cache-failover"
  description = "The cache failed over to its replica"
  event_pattern = jsonencode({
    source        = ["aws.elasticache"]
    "detail-type" = ["ElastiCache Replication Group Failover Completed", "ElastiCache Cache Cluster Failover Completed"]
  })
}

resource "aws_cloudwatch_event_target" "cache_failover" {
  rule = aws_cloudwatch_event_rule.cache_failover.name
  arn  = aws_sns_topic.oncall.arn
}

# ---------------------------------------------------------------- servers (CloudWatch agent, per server group)
resource "aws_cloudwatch_metric_alarm" "server_memory" {
  alarm_name          = "lims-app-memory"
  alarm_description   = "App server memory above 85%"
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.app.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm.actions
  ok_actions          = local.alarm.actions
}

resource "aws_cloudwatch_metric_alarm" "server_disk" {
  alarm_name          = "lims-app-disk"
  alarm_description   = "App server disk above 80%"
  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.app.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm.actions
  ok_actions          = local.alarm.actions
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
