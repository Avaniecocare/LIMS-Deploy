# Step 2: one VPC over two AZs. Public subnets: the load balancer and the NAT gateway. Node subnets: Kubernetes, which
# calls out (the GST portal, WhatsApp, email) through NAT and cannot be reached from the internet. Private subnets, no
# internet route at all: the database.

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "lims-prod", Lab = "shared" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "lims-prod" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  map_public_ip_on_launch = false
  tags                    = { Name = "lims-public-${var.azs[count.index]}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = var.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10 + count.index)
  tags              = { Name = "lims-private-${var.azs[count.index]}" }
}

# Pods take an address each, so these are large.
resource "aws_subnet" "nodes" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = var.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 4 + count.index)
  tags              = { Name = "lims-nodes-${var.azs[count.index]}" }
}

# One NAT gateway by default. A second costs about as much again and keeps outgoing calls working if an AZ fails.
resource "aws_eip" "nat" {
  count  = var.nat_gateways
  domain = "vpc"
  tags   = { Name = "lims-nat-${count.index}" }
}

resource "aws_nat_gateway" "main" {
  count         = var.nat_gateways
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "lims-${var.azs[count.index]}" }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "nodes" {
  count  = 2
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[min(count.index, var.nat_gateways - 1)].id
  }
  tags = { Name = "lims-nodes-${var.azs[count.index]}" }
}

resource "aws_route_table_association" "nodes" {
  count          = 2
  subnet_id      = aws_subnet.nodes[count.index].id
  route_table_id = aws_route_table.nodes[count.index].id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "lims-public" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "lims-private" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# S3 traffic stays inside AWS (free).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id, aws_route_table.private.id], aws_route_table.nodes[*].id)
  tags              = { Name = "lims-s3" }
}

# ---------------------------------------------------------------- flow logs
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/lims/prod/vpc-flow"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "flow" {
  name = "lims-vpc-flow-logs"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "vpc-flow-logs.amazonaws.com" }, Action = "sts:AssumeRole", Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } } }]
  })
}

resource "aws_iam_role_policy" "flow" {
  role = aws_iam_role.flow.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow.arn
  iam_role_arn    = aws_iam_role.flow.arn
}

# ---------------------------------------------------------------- security groups (nothing opens port 22)
resource "aws_security_group" "alb" {
  name        = "lims-alb"
  description = "Load balancer: HTTPS and HTTP from anywhere"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "db" {
  name        = "lims-db"
  description = "RDS: only from the cluster"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_web" {
  for_each          = { https4 = [443, "0.0.0.0/0", null], http4 = [80, "0.0.0.0/0", null], https6 = [443, null, "::/0"], http6 = [80, null, "::/0"] }
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = each.value[0]
  to_port           = each.value[0]
  cidr_ipv4         = each.value[1]
  cidr_ipv6         = each.value[2]
}

# The load balancer sends straight to the pods, whose security group is the cluster's.
resource "aws_vpc_security_group_egress_rule" "alb_to_pods" {
  for_each                     = { ui = 8080, api = 3000 }
  security_group_id            = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "pods_from_alb" {
  for_each                     = { ui = 8080, api = 3000 }
  security_group_id            = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.alb.id
}

# Which pods may open it is the network policies' business: only api, worker and migrate.
resource "aws_vpc_security_group_ingress_rule" "db_from_pods" {
  security_group_id            = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}
