# Steps 4 and 6: Kubernetes. One namespace per company (kubernetes/ in this repository). The nodes are ARM, in private
# subnets, and hold no company's credentials: each company's pods get their own through Pod Identity (modules/lab).

resource "aws_kms_key" "eks" {
  description         = "Kubernetes secrets in lims-prod"
  enable_key_rotation = true
}

resource "aws_kms_alias" "eks" {
  name          = "alias/lims-eks"
  target_key_id = aws_kms_key.eks.key_id
}

resource "aws_iam_role" "eks" {
  name = "lims-eks"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "eks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "eks" {
  role       = aws_iam_role.eks.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Created first so the logs are kept as long as the others, not for ever.
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/lims-prod/cluster"
  retention_in_days = var.log_retention_days
}

resource "aws_eks_cluster" "main" {
  name     = "lims-prod"
  version  = var.eks_version
  role_arn = aws_iam_role.eks.arn

  vpc_config {
    subnet_ids              = aws_subnet.nodes[*].id
    endpoint_private_access = true
    # From the administrators' networks only.
    endpoint_public_access = length(var.admin_cidrs) > 0
    public_access_cidrs    = length(var.admin_cidrs) > 0 ? var.admin_cidrs : null
  }
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }
  encryption_config {
    resources = ["secrets"]
    provider { key_arn = aws_kms_key.eks.arn }
  }
  enabled_cluster_log_types     = ["api", "audit", "authenticator"]
  bootstrap_self_managed_addons = false
  deletion_protection           = true

  depends_on = [aws_iam_role_policy_attachment.eks, aws_cloudwatch_log_group.eks]
}

# People, by role, never by shared credentials.
resource "aws_eks_access_entry" "admin" {
  for_each      = toset(var.cluster_admin_role_arns)
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.key
}

resource "aws_eks_access_policy_association" "admin" {
  for_each      = toset(var.cluster_admin_role_arns)
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.key
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.admin]
}

# ---------------------------------------------------------------- nodes
resource "aws_iam_role" "node" {
  name = "lims-eks-node"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

# Pull images and join the cluster: nothing about any company.
resource "aws_iam_role_policy_attachment" "node" {
  for_each   = toset(["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly", "AmazonSSMManagedInstanceCore"])
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.key}"
}

resource "aws_launch_template" "node" {
  name_prefix = "lims-node-"
  # Pods cannot reach the machine's own credentials: the answer may travel one hop only.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      # The backend image is about 4.5 GB unpacked, and two releases are there during an upgrade.
      volume_size = 60
      volume_type = "gp3"
      encrypted   = true
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "lims-node" })
  }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "arm"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.nodes[*].id
  ami_type        = "AL2023_ARM_64_STANDARD"
  instance_types  = [var.node_instance_type]
  version         = var.eks_version

  scaling_config {
    min_size     = var.node_min
    desired_size = var.node_min
    max_size     = var.node_max
  }
  update_config { max_unavailable = 1 }
  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }
  node_repair_config { enabled = true }

  depends_on = [aws_iam_role_policy_attachment.node, aws_eks_addon.network]
  lifecycle { ignore_changes = [scaling_config[0].desired_size] }
}

# ---------------------------------------------------------------- add-ons
# Without this setting the network policies, which keep companies apart, are accepted and ignored.
resource "aws_eks_addon" "network" {
  cluster_name         = aws_eks_cluster.main.name
  addon_name           = "vpc-cni"
  configuration_values = jsonencode({ enableNetworkPolicy = "true" })
  pod_identity_association {
    role_arn        = aws_iam_role.addon["vpc-cni"].arn
    service_account = "aws-node"
  }
}

resource "aws_eks_addon" "first" {
  for_each     = toset(["kube-proxy", "eks-pod-identity-agent"])
  cluster_name = aws_eks_cluster.main.name
  addon_name   = each.key
}

resource "aws_eks_addon" "main" {
  for_each     = toset(["coredns", "metrics-server"])
  cluster_name = aws_eks_cluster.main.name
  addon_name   = each.key
  depends_on   = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "disks" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"
  pod_identity_association {
    role_arn        = aws_iam_role.addon["ebs-csi"].arn
    service_account = "ebs-csi-controller-sa"
  }
  depends_on = [aws_eks_node_group.main]
}

# ---------------------------------------------------------------- what runs in the cluster and calls AWS
locals {
  pod_identity_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
  addon_roles = {
    vpc-cni = "AmazonEKS_CNI_Policy"
    ebs-csi = "service-role/AmazonEBSCSIDriverPolicy"
  }
}

resource "aws_iam_role" "addon" {
  for_each           = local.addon_roles
  name               = "lims-eks-${each.key}"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy_attachment" "addon" {
  for_each   = local.addon_roles
  role       = aws_iam_role.addon[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.value}"
}

# Keeps the load balancer's target groups filled with pods (TargetGroupBinding). It may not make load balancers: those
# are Terraform's.
resource "aws_iam_role" "targets" {
  name               = "lims-eks-targets"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy" "targets" {
  role = aws_iam_role.targets.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Look"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTargetGroupAttributes", "elasticloadbalancing:DescribeTargetHealth", "elasticloadbalancing:DescribeTags", "elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeListeners", "ec2:DescribeInstances", "ec2:DescribeNetworkInterfaces", "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeVpcs", "ec2:DescribeAvailabilityZones"]
        Resource = "*"
      },
      {
        Sid      = "FillTargetGroups"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets"]
        Resource = "arn:${data.aws_partition.current.partition}:elasticloadbalancing:${var.region}:${local.account_id}:targetgroup/lims-*/*"
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "targets" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.targets.arn
}

# Copies each company's secrets from Secrets Manager into its namespace.
resource "aws_iam_role" "secrets" {
  name               = "lims-eks-external-secrets"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy" "secrets" {
  role = aws_iam_role.secrets.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = "arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${local.account_id}:secret:lims/prod/*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "secrets" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.secrets.arn
}
