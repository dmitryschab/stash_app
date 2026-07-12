terraform {
  required_version = ">= 1.5"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 5.0" }
    tls   = { source = "hashicorp/tls", version = "~> 4.0" }
    local = { source = "hashicorp/local", version = "~> 2.4" }
    http  = { source = "hashicorp/http", version = "~> 3.4" }
  }
}

variable "region" {
  description = "EU region — Stockholm is the cheapest and keeps EU-user data in the EU."
  type        = string
  default     = "eu-north-1"
}

variable "instance_type" {
  description = "t3.micro is free-tier eligible in eu-north-1 (no t2.micro there)."
  type        = string
  default     = "t3.micro"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "stash-box"
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget in USD. AWS Budgets ALERTS at thresholds; it does not hard-stop spend."
  type        = number
  default     = 20
}

variable "alert_email" {
  description = "Email address that receives budget alerts."
  type        = string
  default     = "dmitryschab@gmail.com"
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "stash"
      ManagedBy = "terraform"
    }
  }
}

# Lock SSH to the machine running terraform, not the whole internet.
data "http" "myip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  operator_cidr = "${chomp(data.http.myip.response_body)}/32"
}

# Latest Ubuntu 24.04 LTS from Canonical.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Use the account's default VPC + one of its subnets — no custom networking for a single box.
# ponytail: default VPC, build a real VPC only if this grows past one box.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# SSH key generated locally; private key written to disk (0600) and gitignored.
resource "tls_private_key" "box" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "box" {
  key_name   = "${var.name}-key"
  public_key = tls_private_key.box.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.box.private_key_openssh
  filename        = "${path.module}/${var.name}-key.pem"
  file_permission = "0600"
}

resource "aws_security_group" "box" {
  name        = "${var.name}-sg"
  description = "Stash box: SSH from operator only; HTTP/HTTPS public for the webhook."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from operator IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.operator_cidr]
  }

  ingress {
    description = "HTTP for ACME and HTTPS redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS Data Portability webhook"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "box" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  key_name               = aws_key_pair.box.key_name
  vpc_security_group_ids = [aws_security_group.box.id]

  root_block_device {
    volume_size = 20 # within the 30 GB EBS free-tier allowance
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = var.name }

  # Never replace the running box just because a newer Ubuntu AMI became "most_recent".
  lifecycle {
    ignore_changes = [ami]
  }
}

# Stable public IP so the webhook URL doesn't change on reboot.
# An EIP attached to a running instance is free; it's only billed when unattached.
resource "aws_eip" "box" {
  instance = aws_instance.box.id
  domain   = "vpc"
  tags     = { Name = "${var.name}-eip" }
}

# Monthly cost budget with email alerts. Note: AWS Budgets notify, they do not cap spend.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

output "public_ip" {
  value = aws_eip.box.public_ip
}

output "ssh_command" {
  value = "ssh -i ${local_sensitive_file.private_key.filename} ubuntu@${aws_eip.box.public_ip}"
}
