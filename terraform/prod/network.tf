# Step 2: one VPC over two AZs. Public subnets: the load balancer and the app servers (which call out to the GST
# portal, WhatsApp and email without a NAT gateway). Private subnets, no internet route: the database and cache.

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
  map_public_ip_on_launch = true
  tags                    = { Name = "lims-public-${var.azs[count.index]}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = var.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10 + count.index)
  tags              = { Name = "lims-private-${var.azs[count.index]}" }
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
  route_table_ids   = [aws_route_table.public.id, aws_route_table.private.id]
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
    Statement = [{ Effect = "Allow", Principal = { Service = "vpc-flow-logs.amazonaws.com" }, Action = "sts:AssumeRole" }]
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

resource "aws_security_group" "app" {
  name        = "lims-app"
  description = "App servers: only from the load balancer"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "db" {
  name        = "lims-db"
  description = "RDS: only from the app servers"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "cache" {
  name        = "lims-cache"
  description = "ElastiCache: only from the app servers"
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

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  for_each                     = { ui = [8101, 8199], api = [3101, 3199] }
  security_group_id            = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = each.value[0]
  to_port                      = each.value[1]
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  for_each                     = { ui = [8101, 8199], api = [3101, 3199] }
  security_group_id            = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = each.value[0]
  to_port                      = each.value[1]
  referenced_security_group_id = aws_security_group.alb.id
}

# The servers call out: images, the GST portal, WhatsApp, email, PIN lookup, AWS APIs.
resource "aws_vpc_security_group_egress_rule" "app_out" {
  for_each          = { v4 = ["0.0.0.0/0", null], v6 = [null, "::/0"] }
  security_group_id = aws_security_group.app.id
  ip_protocol       = "-1"
  cidr_ipv4         = each.value[0]
  cidr_ipv6         = each.value[1]
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_app" {
  security_group_id            = aws_security_group.cache.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.app.id
}
