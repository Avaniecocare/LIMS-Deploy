# Step 7: the load balancer (TLS, routing by host name), its access logs and the web firewall. Certificates,
# target groups and routing rules for each company are in the lab module.

locals {
  # The listener's default certificate: the company with the lowest number. The others are added beside it.
  default_lab = length(var.labs) == 0 ? null : [for k, v in var.labs : k if v.number == min([for x in values(var.labs) : x.number]...)][0]
}

data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket" "alb_logs" {
  bucket = "lims-alb-logs-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "keep-180-days"
    status = "Enabled"
    filter {}
    expiration { days = var.log_retention_days }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = data.aws_elb_service_account.main.arn }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.alb_logs.arn}/AWSLogs/${local.account_id}/*"
    }]
  })
}

resource "aws_lb" "main" {
  name                       = "lims-prod"
  internal                   = false
  load_balancer_type         = "application"
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.alb.id]
  idle_timeout               = 120
  enable_deletion_protection = true
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    enabled = true
  }
  depends_on = [aws_s3_bucket_policy.alb_logs]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Created once the first company exists (it needs a certificate). Unknown host names get a plain 404.
resource "aws_lb_listener" "https" {
  count             = local.default_lab == null ? 0 : 1
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.lab[local.default_lab].certificate_arn
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

# ---------------------------------------------------------------- web firewall
locals {
  waf_managed = {
    AWSManagedRulesAmazonIpReputationList = { priority = 10, counted = [] }
    AWSManagedRulesKnownBadInputsRuleSet  = { priority = 20, counted = [] }
    # Uploads exceed the 8 KB body limit, and email templates are HTML: those two rules only count.
    AWSManagedRulesCommonRuleSet = { priority = 30, counted = ["SizeRestrictions_BODY", "CrossSiteScripting_BODY"] }
  }
}

resource "aws_wafv2_web_acl" "main" {
  name  = "lims-prod"
  scope = "REGIONAL"
  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.waf_managed
    content {
      name     = rule.key
      priority = rule.value.priority
      override_action {
        dynamic "none" {
          for_each = var.waf_block ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = var.waf_block ? [] : [1]
          content {}
        }
      }
      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
          dynamic "rule_action_override" {
            for_each = rule.value.counted
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "rate-per-address"
    priority = 40
    action {
      dynamic "block" {
        for_each = var.waf_block ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.waf_block ? [] : [1]
        content {}
      }
    }
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-per-address"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "lims-prod"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "main" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-lims"
  retention_in_days = var.log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  resource_arn            = aws_wafv2_web_acl.main.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
}
