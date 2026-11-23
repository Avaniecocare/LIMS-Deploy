# Step 3: PostgreSQL on RDS (Multi-AZ). Per-company buckets are in the lab module; per-company databases and roles are
# made by kubernetes/create-database.sh. The cache runs in each company's namespace.

locals {
  pg_major = split(".", var.rds_engine_version)[0]
}

# ---------------------------------------------------------------- RDS
resource "aws_db_subnet_group" "main" {
  name       = "lims-prod"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_parameter_group" "pg" {
  name   = "lims-pg${local.pg_major}"
  family = "postgres${local.pg_major}"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name = "lims-rds-monitoring"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "monitoring.rds.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# Created first so the logs are kept 180 days, not forever.
resource "aws_cloudwatch_log_group" "rds" {
  for_each          = toset(["postgresql", "upgrade"])
  name              = "/aws/rds/instance/lims-prod/${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_db_instance" "main" {
  identifier     = "lims-prod"
  engine         = "postgres"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class
  multi_az       = true

  allocated_storage     = var.rds_allocated_storage_gb
  max_allocated_storage = var.rds_max_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.pg.name
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  username                    = "lims_master"
  manage_master_user_password = true

  backup_retention_period    = 35
  backup_window              = "20:30-21:00"         # 02:00-02:30 IST
  maintenance_window         = "sun:00:30-sun:01:30" # 06:00-07:00 IST
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "lims-prod-final"

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  tags       = { Name = "lims-prod", Lab = "shared", Backup = "lims" }
  depends_on = [aws_cloudwatch_log_group.rds]
}

