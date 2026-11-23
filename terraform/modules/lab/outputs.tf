output "summary" {
  description = "What the company's company.properties and create-database.sh need."
  value = {
    namespace              = local.namespace
    S3_BUCKET              = local.bucket
    STORAGE_ORIGIN         = local.storage_url
    bucket_dr              = aws_s3_bucket.files_dr.id
    APP_DOMAIN             = var.domain
    API_DOMAIN             = local.api_domain
    UI_TARGET_GROUP_ARN    = aws_lb_target_group.ui.arn
    API_TARGET_GROUP_ARN   = aws_lb_target_group.api.arn
    COMPANY_SECRET         = aws_secretsmanager_secret.app.name
    COMPANY_MIGRATE_SECRET = aws_secretsmanager_secret.migrate.name
    database               = local.db_name
    db_owner               = local.db_owner
    db_app                 = local.db_app
  }
}
