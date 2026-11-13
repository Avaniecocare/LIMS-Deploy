output "target_group_arns" {
  value = [aws_lb_target_group.ui.arn, aws_lb_target_group.api.arn]
}

output "summary" {
  value = {
    bucket      = aws_s3_bucket.files.id
    bucket_dr   = aws_s3_bucket.files_dr.id
    ssm_path    = local.ssm
    database    = local.db_name
    db_owner    = local.db_owner
    db_app      = local.db_app
    redis_db    = var.number
    ui_port     = local.ui_port
    api_port    = local.api_port
    app_address = "https://${var.domain}"
    api_address = "https://${local.api_domain}"
    setup_token = "${local.ssm}/SETUP_TOKEN (read it with aws ssm get-parameter --with-decryption)"
  }
}
