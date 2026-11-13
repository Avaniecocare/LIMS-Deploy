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
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::123456789012:instance-profile/mock" }
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
  deploy_repo_url     = "https://github.com/example/LIMS-Deploy.git"
  deploy_version      = "v1.0.0"
  github_org          = "example"
  oncall_emails       = ["oncall@example.com"]
  budget_emails       = ["accounts@example.com"]
  app_servers_enabled = true
  labs = {
    alpha = { number = 1, domain = "lims.alpha.example", dns_zone_id = "Z0000000000000000ALPH", image_tag = "1.0.0" }
    beta  = { number = 2, domain = "lims.beta.example", dns_zone_id = null, image_tag = "1.0.0" }
  }
}

run "plans_two_companies" {
  command = plan

  assert {
    condition     = aws_db_instance.main.multi_az && aws_db_instance.main.storage_encrypted && aws_db_instance.main.deletion_protection && aws_db_instance.main.backup_retention_period == 35
    error_message = "The database must be Multi-AZ, encrypted, protected and keep 35 days of backups."
  }
  assert {
    condition     = aws_elasticache_replication_group.main.automatic_failover_enabled && aws_elasticache_replication_group.main.transit_encryption_enabled
    error_message = "The cache must fail over automatically and encrypt traffic."
  }
  assert {
    condition     = one([for p in aws_elasticache_parameter_group.cache.parameter : p.value if p.name == "maxmemory-policy"]) == "noeviction"
    error_message = "The job queue needs noeviction."
  }
  assert {
    condition     = aws_autoscaling_group.app.min_size == 2 && length(aws_subnet.public) == 2 && aws_subnet.public[0].availability_zone != aws_subnet.public[1].availability_zone
    error_message = "Two servers across two AZs."
  }
  assert {
    condition     = aws_launch_template.app.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }
  assert {
    condition     = aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    error_message = "TLS 1.2+ policy on the listener."
  }
  assert {
    condition     = aws_ssm_parameter.labs.value == "alpha:1,beta:2"
    error_message = "Servers read every company and its number."
  }
  assert {
    condition     = length(aws_route53_record.cert_validation) == 2
    error_message = "Only the Route 53 company gets validation records (its two names)."
  }
  assert {
    condition     = module.lab["alpha"].summary.redis_db == 1 && module.lab["beta"].summary.api_port == 3102
    error_message = "Each company gets its own Redis database and ports."
  }
  assert {
    condition     = module.lab["beta"].summary.db_owner == "lims_beta_owner"
    error_message = "Database roles are per company (roles are shared across one RDS instance)."
  }
}

run "no_servers_until_enabled" {
  command = plan
  variables {
    app_servers_enabled = false
  }
  assert {
    condition     = aws_autoscaling_group.app.desired_capacity == 0
    error_message = "No servers before the app changes are released."
  }
}

run "rejects_a_reused_number" {
  command = plan
  variables {
    labs = {
      alpha = { number = 1, domain = "lims.alpha.example", image_tag = "1.0.0" }
      gamma = { number = 1, domain = "lims.gamma.example", image_tag = "1.0.0" }
    }
  }
  expect_failures = [var.labs]
}
