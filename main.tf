# -----------------------------------------------------------------------------
# VPC & Networking
# -----------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "network-dr-lab-vpc"
  }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name = "network-dr-lab-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "network-dr-lab-public"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "network-dr-lab-private"
  }
}

# NAT Gateway 
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "network-dr-lab-nat-eip"
  }
}

resource "aws_nat_gateway" "lab" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "network-dr-lab-nat"
  }

  depends_on = [aws_internet_gateway.lab]
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = {
    Name = "network-dr-lab-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private Route Table — route is conditional 
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name = "network-dr-lab-private-rt"
  }
}

resource "aws_route" "private_nat" {
  count = var.enable_private_outbound ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.lab.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# -----------------------------------------------------------------------------
# Security Group for the private instance
# -----------------------------------------------------------------------------

resource "aws_security_group" "private_instance" {
  name_prefix = "network-dr-lab-private-"
  description = "Security group for private lab instance"
  vpc_id      = aws_vpc.lab.id

  # Allow all outbound (common for private instances)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "network-dr-lab-private-sg"
  }
}

# -----------------------------------------------------------------------------
# IAM Role for SSM Session Manager
# -----------------------------------------------------------------------------

resource "aws_iam_role" "ssm" {
  name_prefix = "network-dr-lab-ssm-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name_prefix = "network-dr-lab-ssm-"
  role        = aws_iam_role.ssm.name
}

# -----------------------------------------------------------------------------
# EC2 Instance in Private Subnet
# -----------------------------------------------------------------------------

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "private" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.private_instance.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  key_name               = var.key_name

  user_data = <<-EOF
    #!/bin/bash
    set -x
    # Garante que o agente está instalado e rodando
    dnf install -y amazon-ssm-agent || yum install -y amazon-ssm-agent
    systemctl enable amazon-ssm-agent
    systemctl restart amazon-ssm-agent
    sleep 10
    systemctl status amazon-ssm-agent > /var/log/ssm-status.log 2>&1
    # Teste de resolução e conectividade básica
    echo "=== DNS Test ===" >> /var/log/ssm-debug.log
    nslookup ssm.sa-east-1.amazonaws.com >> /var/log/ssm-debug.log 2>&1 || true
    curl -v --connect-timeout 5 https://ssm.sa-east-1.amazonaws.com >> /var/log/ssm-debug.log 2>&1 || true
  EOF

  user_data_replace_on_change = true

  tags = {
    Name = "network-dr-lab-private-instance"
  }
}

# -----------------------------------------------------------------------------
# VPC Endpoints for SSM (so we can still access the instance even when NAT route is missing)
# -----------------------------------------------------------------------------

resource "aws_security_group" "endpoints" {
  name_prefix = "network-dr-lab-endpoints-"
  description = "Security group for VPC endpoints"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "network-dr-lab-endpoints-sg"
  }
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.lab.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "network-dr-lab-ssm-endpoint"
  }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.lab.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "network-dr-lab-ssmmessages-endpoint"
  }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.lab.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "network-dr-lab-ec2messages-endpoint"
  }
}

# -----------------------------------------------------------------------------
# VPC Flow Logs
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/flow-logs/network-dr-lab"
  retention_in_days = 7
}

resource "aws_iam_role" "flow_logs" {
  name_prefix = "network-dr-lab-flow-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name_prefix = "network-dr-lab-flow-"
  role        = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "lab" {
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.lab.id

  tags = {
    Name = "network-dr-lab-flow-logs"
  }
}
