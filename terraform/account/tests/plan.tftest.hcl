mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket" }
  }
}

variables {
  budget_emails = ["accounts@example.com"]
}

run "warns_before_the_budget_is_spent" {
  command = plan
  assert {
    condition     = aws_budgets_budget.monthly.limit_amount == "200" && contains([for n in aws_budgets_budget.monthly.notification : n.notification_type], "FORECASTED")
    error_message = "A 200 dollar budget, with a warning from the forecast."
  }
  assert {
    condition     = aws_cloudtrail.main.is_multi_region_trail && aws_cloudtrail.main.enable_log_file_validation
    error_message = "The audit trail covers every region and can be checked for tampering."
  }
}
