# Plans the whole setup against mocked AWS providers (no account, no cost): catches values that cannot be known at
# plan time, missing wiring and broken references. Run: terraform init -backend=false && terraform test

# Plans only: an apply would try to destroy the buckets afterwards, which prevent_destroy rightly refuses.
# Mocked resources return ARNs of the right shape (the provider checks them) and a certificate's DNS proofs.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_elb_service_account" {
    defaults = { arn = "arn:aws:iam::718504428378:root" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_eks_cluster" {
    defaults = { arn = "arn:aws:eks:ap-south-1:123456789012:cluster/lims-prod", vpc_config = [{ cluster_security_group_id = "sg-0123456789abcdef0", vpc_id = "vpc-0123456789abcdef0" }] }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:ap-south-1:123456789012:key/00000000-0000-0000-0000-000000000000", key_id = "00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:mock" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:ap-south-1:123456789012:loadbalancer/app/lims-prod/0123456789abcdef", arn_suffix = "app/lims-prod/0123456789abcdef" }
  }
  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:ap-south-1:123456789012:listener/app/lims-prod/0123456789abcdef/0123456789abcdef" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:ap-south-1:123456789012:targetgroup/mock/0123456789abcdef", arn_suffix = "targetgroup/mock/0123456789abcdef" }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = { arn = "arn:aws:wafv2:ap-south-1:123456789012:regional/webacl/lims-prod/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:ap-south-1:123456789012:log-group:mock" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:ap-south-1:123456789012:lims-oncall" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket" }
  }
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:ap-south-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [
        { domain_name = "lims.alpha.example", resource_record_name = "_a.lims.alpha.example.", resource_record_type = "CNAME", resource_record_value = "_x.acm-validations.aws." },
        { domain_name = "api.lims.alpha.example", resource_record_name = "_b.api.lims.alpha.example.", resource_record_type = "CNAME", resource_record_value = "_y.acm-validations.aws." },
        { domain_name = "lims.beta.example", resource_record_name = "_c.lims.beta.example.", resource_record_type = "CNAME", resource_record_value = "_z.acm-validations.aws." },
        { domain_name = "api.lims.beta.example", resource_record_name = "_d.api.lims.beta.example.", resource_record_type = "CNAME", resource_record_value = "_w.acm-validations.aws." },
      ]
    }
  }
  mock_resource "aws_acm_certificate_validation" {
    defaults = { certificate_arn = "arn:aws:acm:ap-south-1:123456789012:certificate/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_db_instance" {
    defaults = { arn = "arn:aws:rds:ap-south-1:123456789012:db:lims-prod", address = "lims-prod.abc.ap-south-1.rds.amazonaws.com", master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:rds-mock", kms_key_id = "", secret_status = "active" }] }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_ecr_repository" {
    defaults = { arn = "arn:aws:ecr:ap-south-1:123456789012:repository/mock", repository_url = "123456789012.dkr.ecr.ap-south-1.amazonaws.com/mock" }
  }
}
mock_provider "aws" {
  alias = "dr"
  mock_resource "aws_backup_vault" {
    defaults = { arn = "arn:aws:backup:ap-south-2:123456789012:backup-vault:lims-dr" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket-dr" }
  }
}
mock_provider "aws" {
  alias = "use1"
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:123456789012:lims-oncall" }
  }
}

variables {
  github_org              = "example"
  oncall_emails           = ["oncall@example.com"]
  budget_emails           = ["accounts@example.com"]
  cluster_admin_role_arns = ["arn:aws:iam::123456789012:role/admin"]
  admin_cidrs             = ["203.0.113.0/24"]
  labs = {
    alpha = { number = 1, domain = "lims.alpha.example", dns_zone_id = "Z0000000000000000ALPH" }
    beta  = { number = 2, domain = "lims.beta.example", dns_zone_id = null }
  }
}

run "plans_two_companies" {
  command = plan

  assert {
    condition     = aws_db_instance.main.multi_az && aws_db_instance.main.storage_encrypted && aws_db_instance.main.deletion_protection && aws_db_instance.main.backup_retention_period == 35
    error_message = "The database must be Multi-AZ, encrypted, protected and keep 35 days of backups."
  }
  assert {
    condition     = aws_eks_cluster.main.encryption_config[0].resources == toset(["secrets"]) && aws_eks_cluster.main.deletion_protection && aws_eks_cluster.main.access_config[0].authentication_mode == "API"
    error_message = "The cluster must encrypt secrets with our key, be protected, and know people by IAM role only."
  }
  assert {
    condition     = jsondecode(aws_eks_addon.network.configuration_values).enableNetworkPolicy == "true"
    error_message = "Without this, the network policies that keep companies apart are ignored."
  }
  assert {
    condition     = aws_launch_template.node.metadata_options[0].http_tokens == "required" && aws_launch_template.node.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "Pods must not reach the node's own credentials."
  }
  assert {
    condition     = aws_eks_node_group.main.scaling_config[0].min_size >= 2 && aws_subnet.nodes[0].availability_zone != aws_subnet.nodes[1].availability_zone && coalesce(aws_subnet.nodes[0].map_public_ip_on_launch, false) == false
    error_message = "Two nodes across two AZs, without public addresses."
  }
  assert {
    condition     = output.network.VPC_PUBLIC_CIDR == "10.20.0.0/23" && output.network.VPC_DATA_CIDR == "10.20.10.0/23" && aws_subnet.public[1].cidr_block == "10.20.1.0/24" && aws_subnet.private[1].cidr_block == "10.20.11.0/24"
    error_message = "The network policies' ranges must cover exactly the load balancer's and the database's subnets."
  }
  assert {
    condition     = aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    error_message = "TLS 1.2+ policy on the listener."
  }
  assert {
    condition     = length(aws_route53_record.cert_validation) == 2
    error_message = "Only the Route 53 company gets validation records (its two names)."
  }
  assert {
    condition     = module.lab["alpha"].summary.namespace == "lims-alpha" && module.lab["alpha"].summary.COMPANY_SECRET == "lims/prod/alpha/app" && module.lab["beta"].summary.S3_BUCKET != module.lab["alpha"].summary.S3_BUCKET
    error_message = "Each company gets its own namespace, secrets and bucket."
  }
  assert {
    condition     = length(aws_iam_role.ci_push) == 2 && aws_iam_role.ci_push["lims"].name != aws_iam_role.ci_push["lims-ui"].name && output.ci_subjects["lims-ui"] == "repo:example/LIMS-UI:ref:refs/tags/v*"
    error_message = "Each repository pushes its own image, from release tags."
  }
  assert {
    condition     = module.lab["beta"].summary.db_owner == "lims_beta_owner"
    error_message = "Database roles are per company (roles are shared across one RDS instance)."
  }
}

run "the_kubernetes_api_is_never_open_to_everyone" {
  command = plan
  variables {
    admin_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.admin_cidrs]
}

run "closed_from_outside_by_default" {
  command = plan
  variables {
    admin_cidrs = []
  }
  assert {
    condition     = !aws_eks_cluster.main.vpc_config[0].endpoint_public_access
    error_message = "With no networks named, only from inside."
  }
}

run "rejects_a_reused_number" {
  command = plan
  variables {
    labs = {
      alpha = { number = 1, domain = "lims.alpha.example" }
      gamma = { number = 1, domain = "lims.gamma.example" }
    }
  }
  expect_failures = [var.labs]
}
