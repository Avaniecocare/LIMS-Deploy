# The server. Everything that matters is on the data disk, mounted at /srv: Docker's own data (databases, files,
# images), the companies' folders, local backups and the checkout of this repository. Replacing the server keeps it.

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_disk_gb
  type              = "gp3"
  encrypted         = true
  snapshot_id       = var.data_snapshot_id
  tags              = { Name = "lims-data", Snapshot = "hourly" }
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [snapshot_id]
  }
}

resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.server.id
  stop_instance_before_detaching = true
}

resource "aws_instance" "server" {
  ami                     = data.aws_ssm_parameter.ubuntu.insecure_value
  instance_type           = var.instance_type
  iam_instance_profile    = aws_iam_instance_profile.server.name
  disable_api_termination = true

  primary_network_interface {
    network_interface_id = aws_network_interface.server.id
  }

  # One hop only: the containers cannot reach the server's own credentials.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Standard: a busy spell slows down instead of adding to the bill. An alarm says when credits run low.
  dynamic "credit_specification" {
    for_each = startswith(var.instance_type, "t") ? [1] : []
    content { cpu_credits = "standard" }
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  user_data = templatefile("${path.module}/files/setup.sh.tftpl", {
    volume_id = replace(aws_ebs_volume.data.id, "-", "")
    region    = var.region
    metrics   = file("${path.module}/files/server-metrics.sh")
  })

  tags = { Name = "lims-server" }

  # The set-up script needs the internet from its first line.
  depends_on = [aws_eip_association.server, aws_route_table_association.public, aws_vpc_security_group_egress_rule.out]

  # A newer base image or set-up script must never replace a running server by surprise; use -replace to do it.
  lifecycle { ignore_changes = [ami, user_data] }
}

# ---------------------------------------------------------------- what the server may do
resource "aws_iam_role" "server" {
  name = "lims-server"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_instance_profile" "server" {
  name = "lims-server"
  role = aws_iam_role.server.name
}

# Session Manager: how people get a shell, with their own identity and no open port.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "server" {
  role = aws_iam_role.server.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AddBackupsNeverReadOrDelete"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.backups.arn}/*"
      },
      {
        Sid      = "ReadReleases"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.releases.arn}/*"
      },
      {
        Sid       = "Metrics"
        Effect    = "Allow"
        Action    = "cloudwatch:PutMetricData"
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = "LIMS/Server" } }
      },
    ]
  })
}
