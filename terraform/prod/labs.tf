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
  cluster_name           = aws_eks_cluster.main.name
  pod_identity_trust     = local.pod_identity_trust
  alarm_topic_arn        = aws_sns_topic.oncall.arn
  alarm_topic_use1_arn   = aws_sns_topic.oncall_use1.arn
}
