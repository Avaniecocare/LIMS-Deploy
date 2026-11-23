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

output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "network" {
  description = "For each company's company.properties."
  value       = { VPC_PUBLIC_CIDR = cidrsubnet(var.vpc_cidr, 7, 0), VPC_DATA_CIDR = cidrsubnet(var.vpc_cidr, 7, 5) }
}

output "image_registry" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "ci_role_arn" {
  description = "Set in each repository as the role GitHub Actions assumes to push its image."
  value       = { for k, r in aws_iam_role.ci_push : k => r.arn }
}

output "ci_subjects" {
  description = "Who may take each role."
  value       = local.ci_subjects
}

output "labs" {
  value = { for k, m in module.lab : k => m.summary }
}

output "certificate_validation" {
  description = "Per company: DNS records to add when its DNS is not in Route 53."
  value       = { for k, c in aws_acm_certificate.lab : k => [for o in c.domain_validation_options : { name = o.resource_record_name, type = o.resource_record_type, value = o.resource_record_value }] }
}
