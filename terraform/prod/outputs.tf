output "load_balancer_dns" {
  description = "Point each company's domain and api.<domain> here (CNAME), when DNS is not in Route 53."
  value       = aws_lb.main.dns_name
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "rds_master_secret_arn" {
  description = "The master password, in Secrets Manager."
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "cache_endpoint" {
  value = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "image_registry" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "ci_role_arn" {
  description = "Set as the role GitHub Actions assumes to push images."
  value       = aws_iam_role.ci_push.arn
}

output "labs" {
  value = { for k, m in module.lab : k => m.summary }
}

output "certificate_validation" {
  description = "Per company: DNS records to add when its DNS is not in Route 53."
  value       = { for k, c in aws_acm_certificate.lab : k => [for o in c.domain_validation_options : { name = o.resource_record_name, type = o.resource_record_type, value = o.resource_record_value }] }
}
