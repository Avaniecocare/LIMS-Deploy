# Alarms by email. The server sends its own figures every five minutes (files/server-metrics.sh); silence is an alarm
# too. The health checks look from outside.

resource "aws_sns_topic" "oncall" {
  name = "lims-server-oncall"
}

resource "aws_sns_topic" "oncall_use1" {
  provider = aws.use1
  name     = "lims-server-oncall"
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

locals {
  server_alarms = {
    disk      = { metric = "DiskUsedPercent", above = 80, periods = 1, text = "The data disk is over 80% full" }
    root      = { metric = "RootDiskUsedPercent", above = 85, periods = 1, text = "The system disk is over 85% full" }
    memory    = { metric = "MemoryUsedPercent", above = 92, periods = 3, text = "Memory over 92% used for 15 minutes" }
    unhealthy = { metric = "UnhealthyContainers", above = 0, periods = 3, text = "A container has been unhealthy or restarting for 15 minutes" }
    backup    = { metric = "BackupAgeHours", above = 30, periods = 1, text = "A company has no good backup in the last 30 hours" }
  }
}

resource "aws_cloudwatch_metric_alarm" "server" {
  for_each            = local.server_alarms
  alarm_name          = "lims-server-${each.key}"
  alarm_description   = each.value.text
  namespace           = "LIMS/Server"
  metric_name         = each.value.metric
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = each.value.periods
  threshold           = each.value.above
  comparison_operator = "GreaterThanThreshold"
  # No figures means the server, or what sends them, has stopped. Only the disk alarm says so, to send one email, not five.
  treat_missing_data = each.key == "disk" ? "breaching" : "ignore"
  alarm_actions      = [aws_sns_topic.oncall.arn]
  ok_actions         = [aws_sns_topic.oncall.arn]
}

# AWS moves the server to other hardware by itself when the hardware fails; this covers the operating system hanging.
resource "aws_cloudwatch_metric_alarm" "instance_check" {
  alarm_name          = "lims-server-not-answering"
  alarm_description   = "The server stopped answering for 5 minutes and is being restarted"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions          = { InstanceId = aws_instance.server.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = ["arn:aws:automate:${var.region}:ec2:reboot", aws_sns_topic.oncall.arn]
  ok_actions          = [aws_sns_topic.oncall.arn]
}

resource "aws_cloudwatch_metric_alarm" "cpu_credits" {
  count               = startswith(var.instance_type, "t") ? 1 : 0
  alarm_name          = "lims-server-cpu-credits"
  alarm_description   = "Almost out of CPU credits: the server will slow down. If this keeps happening, choose a larger type"
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  dimensions          = { InstanceId = aws_instance.server.id }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 30
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [aws_sns_topic.oncall.arn]
  ok_actions          = [aws_sns_topic.oncall.arn]
}

resource "aws_route53_health_check" "api" {
  for_each          = var.health_check_hosts
  fqdn              = each.key
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health/ready"
  request_interval  = 30
  failure_threshold = 3
  tags              = { Name = each.key }
}

resource "aws_cloudwatch_metric_alarm" "outside" {
  for_each            = var.health_check_hosts
  provider            = aws.use1
  alarm_name          = "lims-outside-${each.key}"
  alarm_description   = "${each.key} cannot be reached from the internet"
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.api[each.key].id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.oncall_use1.arn]
  ok_actions          = [aws_sns_topic.oncall_use1.arn]
}
