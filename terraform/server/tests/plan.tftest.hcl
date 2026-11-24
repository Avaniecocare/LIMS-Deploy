# Plans the single-server setup against mocked AWS (no account, no cost): terraform init -backend=false && terraform test
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:ap-south-1:123456789012:mock" }
  }
}
mock_provider "aws" {
  alias = "dr"
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-backups" }
  }
}
mock_provider "aws" {
  alias = "use1"
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:123456789012:mock" }
  }
}

variables {
  oncall_emails      = ["oncall@example.com"]
  health_check_hosts = ["api.lims.alpha.example", "api.lims.beta.example"]
}

run "one_protected_server" {
  command = plan

  assert {
    condition     = aws_instance.server.metadata_options[0].http_tokens == "required" && aws_instance.server.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "Containers must not reach the server's own credentials."
  }
  assert {
    condition     = aws_ebs_volume.data.encrypted && aws_instance.server.root_block_device[0].encrypted && aws_instance.server.disable_api_termination
    error_message = "Disks encrypted, server protected."
  }
  assert {
    condition     = toset([for r in aws_vpc_security_group_ingress_rule.web : r.from_port]) == toset([80, 443])
    error_message = "Only web traffic comes in: no SSH, database or storage port."
  }
  assert {
    condition     = aws_s3_bucket.backups.object_lock_enabled && aws_s3_bucket_object_lock_configuration.backups.rule[0].default_retention[0].mode == "COMPLIANCE"
    error_message = "Nobody can delete a recent backup."
  }
  assert {
    condition     = aws_instance.server.credit_specification[0].cpu_credits == "standard"
    error_message = "A busy spell must not add to the bill."
  }
  assert {
    condition     = length(aws_route53_health_check.api) == 2 && aws_route53_health_check.api["api.lims.alpha.example"].resource_path == "/health/ready"
    error_message = "Every company is watched from outside."
  }
  assert {
    condition     = length([for s in aws_dlm_lifecycle_policy.data.policy_details[0].schedule : s if s.create_rule[0].interval == 1 && s.retain_rule[0].count == 24]) == 1
    error_message = "The data disk is copied every hour."
  }
}

run "the_server_can_add_backups_but_not_read_or_remove_them" {
  command = plan
  override_resource {
    target          = aws_s3_bucket.backups
    override_during = plan
    values          = { arn = "arn:aws:s3:::mock-backups" }
  }
  override_resource {
    target          = aws_s3_bucket.releases
    override_during = plan
    values          = { arn = "arn:aws:s3:::mock-releases" }
  }
  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.server.policy).Statement : s.Action if startswith(s.Resource, "arn:aws:s3:::mock-backups")] == [["s3:PutObject", "s3:AbortMultipartUpload"]]
    error_message = "Only adding."
  }
}

run "arm_only" {
  command = plan
  variables {
    instance_type = "t3.large"
  }
  expect_failures = [var.instance_type]
}

run "locked_backups_are_kept_at_least_as_long" {
  command = plan
  variables {
    backup_keep_days = 7
  }
  expect_failures = [var.backup_keep_days]
}
