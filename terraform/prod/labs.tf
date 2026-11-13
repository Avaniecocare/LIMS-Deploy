# One module per company in var.labs: adding a company is adding an entry and applying (see docs/aws/companies.md).

module "lab" {
  source   = "../modules/lab"
  for_each = var.labs
  providers = {
    aws      = aws
    aws.dr   = aws.dr
    aws.use1 = aws.use1
  }

  slug                   = each.key
  number                 = each.value.number
  domain                 = each.value.domain
  dns_zone_id            = each.value.dns_zone_id
  image_tag              = each.value.image_tag
  account_id             = local.account_id
  region                 = var.region
  vpc_id                 = aws_vpc.main.id
  listener_arn           = aws_lb_listener.https[0].arn
  certificate_arn        = aws_acm_certificate_validation.lab[each.key].certificate_arn
  is_default_certificate = each.key == local.default_lab
  alb_arn_suffix         = aws_lb.main.arn_suffix
  alb_dns_name           = aws_lb.main.dns_name
  alb_zone_id            = aws_lb.main.zone_id
  rds_address            = aws_db_instance.main.address
  redis_address          = aws_elasticache_replication_group.main.primary_endpoint_address
  redis_auth_token       = random_password.cache_auth.result
  alarm_topic_arn        = aws_sns_topic.oncall.arn
  alarm_topic_use1_arn   = aws_sns_topic.oncall_use1.arn
  log_retention_days     = var.log_retention_days
}

# What every server reads at start: which companies to run, and which deploy-script release.
resource "aws_ssm_parameter" "labs" {
  name  = "/lims/prod/labs"
  type  = "String"
  value = length(var.labs) == 0 ? "none" : join(",", [for k, v in var.labs : "${k}:${v.number}"])
}

resource "aws_ssm_parameter" "deploy_version" {
  name  = "/lims/prod/deploy-version"
  type  = "String"
  value = var.deploy_version
}

resource "aws_ssm_parameter" "image_registry" {
  name  = "/lims/prod/image-registry"
  type  = "String"
  value = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}
