# Steps 4 and 6: the servers' role (no stored AWS keys), the launch template and the Auto Scaling group that keeps
# one server in each AZ. Every server builds itself from nothing at start (user-data.sh.tftpl).

resource "aws_iam_role" "app" {
  name = "lims-app-server"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "app_managed" {
  for_each   = toset(["AmazonSSMManagedInstanceCore", "CloudWatchAgentServerPolicy"])
  role       = aws_iam_role.app.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.key}"
}

resource "aws_iam_role_policy" "app" {
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "EcrLogin", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Sid      = "EcrPull"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = [for r in aws_ecr_repository.app : r.arn]
      },
      {
        Sid      = "LabBuckets"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::lims-*-files-${local.account_id}"
      },
      {
        # Never s3:BypassGovernanceRetention: issued reports stay locked.
        Sid      = "LabObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:GetObjectVersion", "s3:PutObjectRetention", "s3:GetObjectRetention"]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::lims-*-files-${local.account_id}/*"
      },
      {
        Sid      = "Settings"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${local.account_id}:parameter/lims/prod/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "lims-app-server"
  role = aws_iam_role.app.name
}

data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_launch_template" "app" {
  name                   = "lims-app"
  image_id               = data.aws_ssm_parameter.al2023_arm.value
  instance_type          = var.app_instance_type
  update_default_version = true

  iam_instance_profile { arn = aws_iam_instance_profile.app.arn }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.app.id]
    delete_on_termination       = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh.tftpl", {
    region          = var.region
    deploy_repo_url = var.deploy_repo_url
    compose_version = var.compose_version
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "lims-app", Lab = "shared" })
  }
  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = "lims-app", Lab = "shared" })
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "lims-app"
  vpc_zone_identifier       = aws_subnet.public[*].id
  min_size                  = var.app_servers_enabled ? 2 : 0
  desired_capacity          = var.app_servers_enabled ? 2 : 0
  max_size                  = var.app_servers_enabled ? 3 : 0
  health_check_type         = "ELB"
  health_check_grace_period = 300
  target_group_arns         = flatten([for m in module.lab : m.target_group_arns])

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # A changed launch template (new image, new script) rolls out one server at a time.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 300
    }
  }

  tag {
    key                 = "Name"
    value               = "lims-app"
    propagate_at_launch = true
  }
}
