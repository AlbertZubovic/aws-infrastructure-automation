# Terraform and Provider setup
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Network data sources
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security Groups
# Frontend ALB SG
resource "aws_security_group" "frontend_alb" {
  name_prefix = "a2-fe-alb-sg-"
  description = "Frontend ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Backend ALB SG
resource "aws_security_group" "backend_alb" {
  name_prefix = "a2-be-alb-sg-"
  description = "Backend ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Frontend instances:
resource "aws_security_group" "frontend" {
  name_prefix = "a2-frontend-sg-"
  description = "Frontend host"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_alb.id]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Backend instances:
resource "aws_security_group" "backend" {
  name_prefix = "a2-backend-sg-"
  description = "Backend host"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.backend_alb.id]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# DB:
resource "aws_security_group" "db" {
  name_prefix = "a2-db-sg-"
  description = "DB host"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 instances
data "aws_ami" "al2023" {
  most_recent = true
  owners = ["137112412989"]
  filter {
    name = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# DB host
resource "aws_instance" "db" {
  ami = data.aws_ami.al2023.id
  instance_type = "t3.micro"
  subnet_id = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.db.id]
  key_name = var.key_name
  associate_public_ip_address = true
  tags = { Name = "a2-db-ec2" }

  instance_initiated_shutdown_behavior = "stop"

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    delete_on_termination = true
  }
}

# Backend host
resource "aws_instance" "backend" {
  count                       = 2
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.backend.id]
  key_name                    = var.key_name
  associate_public_ip_address = true
  tags                        = { Name = "a2-backend-ec2-${count.index}" }

  instance_initiated_shutdown_behavior = "stop"

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }
}

# Frontend host
resource "aws_instance" "frontend" {
  count                       = 2
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.frontend.id]
  key_name                    = var.key_name
  associate_public_ip_address = true
  tags                        = { Name = "a2-frontend-ec2-${count.index}" }

  instance_initiated_shutdown_behavior = "stop"

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }
}

# Application Load Balancers
# Frontend ALB
resource "aws_lb" "frontend" {
  name               = "a2-frontend-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.frontend_alb.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "frontend" {
  name        = "a2-frontend-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 5
    interval            = 30
    timeout             = 5
    matcher             = "200-399"
  }
}

resource "aws_lb_listener" "frontend" {
  load_balancer_arn = aws_lb.frontend.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

resource "aws_lb_target_group_attachment" "frontend" {
  for_each         = { for i in aws_instance.frontend : i.id => i }
  target_group_arn = aws_lb_target_group.frontend.arn
  target_id        = each.key
  port             = 80
}

# ADDED: Backend ALB
resource "aws_lb" "backend" {
  name               = "a2-backend-alb"
  load_balancer_type = "application"
  internal           = true
  security_groups    = [aws_security_group.backend_alb.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "backend" {
  name        = "a2-backend-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 5
    interval            = 30
    timeout             = 5
    matcher             = "200-399"
  }
}

resource "aws_lb_listener" "backend" {
  load_balancer_arn = aws_lb.backend.arn
  port              = 8000
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

resource "aws_lb_target_group_attachment" "backend" {
  for_each         = { for i in aws_instance.backend : i.id => i }
  target_group_arn = aws_lb_target_group.backend.arn
  target_id        = each.key
  port             = 8000
}
