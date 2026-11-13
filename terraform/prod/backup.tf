# Step 9: AWS Backup. Daily copies kept 35 days and monthly copies kept 7 years, each copied to Hyderabad. RDS's own
# point-in-time restore (35 days) runs alongside; S3 versioning and replication cover the files.

resource "aws_backup_vault" "prod" {
  name = "lims-prod"
}

resource "aws_backup_vault" "dr" {
  provider = aws.dr
  name     = "lims-dr"
}

# After the cooling-off days a compliance-mode lock can never be removed, not even by the root user.
resource "aws_backup_vault_lock_configuration" "dr" {
  count               = var.enable_backup_vault_lock ? 1 : 0
  provider            = aws.dr
  backup_vault_name   = aws_backup_vault.dr.name
  min_retention_days  = 35
  max_retention_days  = 2557
  changeable_for_days = var.vault_lock_cooling_off_days
}

resource "aws_iam_role" "backup" {
  name = "lims-backup"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "backup.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each   = toset(["AWSBackupServiceRolePolicyForBackup", "AWSBackupServiceRolePolicyForRestores"])
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/${each.key}"
}

resource "aws_backup_plan" "prod" {
  name = "lims-prod"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.prod.name
    schedule          = "cron(30 21 * * ? *)" # 03:00 IST
    start_window      = 60
    completion_window = 360
    lifecycle { delete_after = 35 }
    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn
      lifecycle { delete_after = 35 }
    }
  }

  rule {
    rule_name         = "monthly"
    target_vault_name = aws_backup_vault.prod.name
    schedule          = "cron(0 22 1 * ? *)"
    start_window      = 60
    completion_window = 720
    lifecycle { delete_after = 2557 } # 7 years
    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn
      lifecycle { delete_after = 2557 }
    }
  }
}

resource "aws_backup_selection" "prod" {
  name         = "lims-tagged"
  plan_id      = aws_backup_plan.prod.id
  iam_role_arn = aws_iam_role.backup.arn
  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Backup"
    value = "lims"
  }
}
