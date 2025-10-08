# Terraform and Provider setup
terraform {
  # Require Terraform
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Network data sources
data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter { name = "vpc-id" values = [data.aws_vpc.default.id] }
}

# Security group for app
resource "aws_security_group" "app" {
  name        = "a2-app-sg"
  description = "Allow SSH/HTTP/Backend"
  vpc_id      = data.aws_vpc.default.id

  # Ansible
  ingress { from_port = 22   to_port = 22   protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  # HTTP
  ingress { from_port = 80   to_port = 80   protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  # Backend
  ingress { from_port = 8000 to_port = 8000 protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }

  egress  { from_port = 0 to_port = 0 protocol = "-1" cidr_blocks = ["0.0.0.0/0"] }
}
