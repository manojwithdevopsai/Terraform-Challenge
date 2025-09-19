# -----------------------
# VPC, IGW, Subnets
# -----------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "tf-vpc-main" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "tf-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags                    = { Name = "tf-public-subnet" }
}

resource "aws_subnet" "private" {
  count                   = length(var.private_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  map_public_ip_on_launch = false
  availability_zone       = data.aws_availability_zones.available.names[count.index + 0]
  tags                    = { Name = "tf-private-subnet-${count.index + 1}" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# -----------------------
# Route tables
# -----------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "tf-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
  depends_on = [ aws_internet_gateway.igw ]
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private route tables will point to NAT gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "tf-private-rt" }
}

resource "aws_route_table_association" "private_assoc" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# -----------------------
# Elastic IP for NAT and NAT Gateway
# -----------------------
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = { Name = "tf-nat-eip" }
}

resource "aws_nat_gateway" "natgw" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags = { Name = "tf-natgw" }
  depends_on = [aws_eip.nat, aws_internet_gateway.igw]
}

# Add default route in each private RT pointing to NAT
resource "aws_route" "private_nat" {
  route_table_id          = aws_route_table.private.id
  destination_cidr_block  = "0.0.0.0/0"
  nat_gateway_id          = aws_nat_gateway.natgw.id
  depends_on              = [aws_nat_gateway.natgw]
}

# -----------------------
# Security Groups
# -----------------------
# 1) NLB SG: inbound tcp:80 from anywhere (0.0.0.0/0)
resource "aws_security_group" "nlb_sg" {
  name        = "nlb-sg"
  description = "Allow tcp:80 from anywhere to NLB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description      = "http from anywhere"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sg-nlb" }
}

# 2) ALB SG: inbound tcp:80 from NLB SG
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow tcp:80 from NLB security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description                 = "http from NLB SG"
    from_port                   = 80
    to_port                     = 80
    protocol                    = "tcp"
    security_groups             = [aws_security_group.nlb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sg-alb" }
}

# 3) VM SG: inbound tcp:80 from ALB SG
resource "aws_security_group" "vm_sg" {
  name        = "vm-sg"
  description = "Allow tcp:80 from ALB security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "http from ALB SG"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sg-vm" }
}

# -----------------------
# Ubuntu AMI lookup
# -----------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
}

# -----------------------
# EC2 instances in private subnets (one per private subnet)
# Install & enable nginx in user_data
# -----------------------
resource "aws_instance" "private_vm" {
  count                     = length(aws_subnet.private)
  ami                       = data.aws_ami.ubuntu.id
  instance_type             = var.instance_type
  subnet_id                 = aws_subnet.private[count.index].id
  associate_public_ip_address = false
  vpc_security_group_ids    = [aws_security_group.vm_sg.id]
  key_name                  = var.key_name != "" ? var.key_name : null
  tags = {
    Name = "tf-private-vm-${count.index + 1}"
  }
  user_data = file("userdata.sh")
  depends_on = [aws_nat_gateway.natgw] # Ensure NAT GW is ready before launching instances
}

# -----------------------
# ALB (internal) + Target Group + Listener
# -----------------------
resource "aws_lb" "alb_internal" {
  name               = "tf-alb-internal"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [for s in aws_subnet.private : s.id]
  tags               = { Name = "tf-alb-internal" }
}

resource "aws_lb_target_group" "alb_tg" {
  name        = "tf-alb-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 6
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = { Name = "tf-alb-tg" }
}

resource "aws_lb_target_group_attachment" "alb_attach" {
  count            = length(aws_instance.private_vm)
  target_group_arn = aws_lb_target_group.alb_tg.arn
  target_id        = aws_instance.private_vm[count.index].id
  port             = 80
}

resource "aws_lb_listener" "alb_listener" {
  load_balancer_arn = aws_lb.alb_internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_tg.arn
  }
}

# -------------------------------
# Data sources
# -------------------------------
data "aws_lb" "app_alb" {
  name = "tf-alb-internal"
  depends_on = [ aws_lb.alb_internal ]
}

data "aws_lb_target_group" "alb_tg" {
  name = "tf-alb-tg"
  depends_on = [aws_lb.alb_internal ]
}

resource "null_resource" "wait_for_alb_tg" {
  provisioner "local-exec" {
    environment = {
      TG_ARN       = data.aws_lb_target_group.alb_tg.arn
      TARGET_COUNT = length(aws_instance.private_vm)
      AWS_REGION   = "us-west-2"
    }

    command = <<EOT
      Write-Output "Waiting for ALB target group health..."
      for ($i = 0; $i -lt 30; $i++) {
          $status = aws elbv2 describe-target-health `
            --target-group-arn $env:TG_ARN `
            --region $env:AWS_REGION `
            --query "TargetHealthDescriptions[].TargetHealth.State" `
            --output text

          Write-Output "Current health states: $status"

          # Split by whitespace and count "healthy"
          $healthy = ($status -split "\s+" | Where-Object { $_.Trim() -eq "healthy" }).Count

          if ($healthy -ge $env:TARGET_COUNT) {
              Write-Output "All targets healthy ✅"
              exit 0
          }

          Write-Output "Not healthy yet... retrying in 10s"
          Start-Sleep -Seconds 10
      }

      Write-Output "Timed out waiting for healthy targets ❌"
      exit 1
    EOT

    interpreter = ["PowerShell", "-Command"]
  }
}

# -----------------------
# NLB (Internet-facing) + ALB Target
# -----------------------

# Network Load Balancer
resource "aws_lb" "nlb" {
  name               = "tf-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [aws_subnet.public.id]
  security_groups    = [aws_security_group.nlb_sg.id]

  tags = {
    Name = "tf-nlb"
  }

  depends_on = [null_resource.wait_for_alb_tg] # optional
}

# NLB Target Group pointing to ALB
resource "aws_lb_target_group" "nlb_tg" {
  name        = "tf-nlb-tg"
  port        = 80
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "alb"

  health_check {
    enabled             = true
    protocol            = "HTTP"          # must be HTTP/HTTPS for ALB targets
    port                = "traffic-port"  # match ALB listener port
    path                = "/"             # ALB must respond with 200
    interval            = 30
    timeout             = 6
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name = "tf-nlb-tg"
  }
}

# Attach ALB to NLB Target Group
resource "aws_lb_target_group_attachment" "nlb_attach_alb" {
  target_group_arn = aws_lb_target_group.nlb_tg.arn
  target_id        = aws_lb.alb_internal.arn  # Pass ALB ARN as a variable
  port             = 80

  depends_on = [aws_lb.nlb]
}

# NLB Listener
resource "aws_lb_listener" "nlb_listener" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_tg.arn
  }

  depends_on = [aws_lb_target_group_attachment.nlb_attach_alb]
}
