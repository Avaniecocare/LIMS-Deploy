# One public subnet and one server. Only HTTP and HTTPS come in; there is no SSH (Session Manager instead), and no NAT
# gateway or load balancer to pay for.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "lims-server" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "lims-server" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.availability_zone
  cidr_block              = var.vpc_cidr
  map_public_ip_on_launch = false
  tags                    = { Name = "lims-server" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# The VPC's default group allows everything inside it; with no rules here, nothing can use it by accident.
resource "aws_default_security_group" "unused" {
  vpc_id = aws_vpc.main.id
}

resource "aws_security_group" "server" {
  name        = "lims-server"
  description = "Web traffic only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "lims-server" }
}

resource "aws_vpc_security_group_ingress_rule" "web" {
  for_each          = { http = { port = 80, protocol = "tcp" }, https = { port = 443, protocol = "tcp" }, http3 = { port = 443, protocol = "udp" } }
  security_group_id = aws_security_group.server.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = each.value.protocol
  description       = each.key
}

resource "aws_vpc_security_group_egress_rule" "out" {
  security_group_id = aws_security_group.server.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Email, GST portal, WhatsApp, certificates, updates"
}

# The server's network card, with the address the companies' DNS points at. Both outlive the server, and the address
# is in place before the server first starts.
resource "aws_network_interface" "server" {
  subnet_id       = aws_subnet.public.id
  security_groups = [aws_security_group.server.id]
  tags            = { Name = "lims-server" }
}

resource "aws_eip" "server" {
  domain     = "vpc"
  tags       = { Name = "lims-server" }
  depends_on = [aws_internet_gateway.main]
  lifecycle { prevent_destroy = true }
}

resource "aws_eip_association" "server" {
  allocation_id        = aws_eip.server.id
  network_interface_id = aws_network_interface.server.id
}
