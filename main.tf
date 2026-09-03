# =============================================================================
# Cryptographic Password Generation
# =============================================================================

resource "random_password" "ca_password" {
  length           = 32
  special          = false
  override_special = ""
}

resource "random_password" "radius_secret" {
  length           = 24
  special          = false
  override_special = ""
}

# =============================================================================
# Network Resolution (VPC, Subnet, and AZ)
# =============================================================================

data "aws_vpc" "selected" {
  default = var.vpc_id == null ? true : null
  id      = var.vpc_id
}

data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
}

locals {
  vpc_id    = data.aws_vpc.selected.id
  subnet_id = var.subnet_id != null ? var.subnet_id : data.aws_subnets.selected.ids[0]
}

data "aws_subnet" "selected" {
  id = local.subnet_id
}

# =============================================================================
# AMI Discovery: Ubuntu 24.04 LTS Minimal (ARM64 for AWS Graviton)
# =============================================================================

data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical official owner ID

  filter {
    name   = "name"
    values = ["ubuntu-minimal/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-minimal-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# =============================================================================
# IAM Configuration for AWS Systems Manager (SSM)
# Zero-trust management: Eliminates requirement for public SSH port 22
# =============================================================================

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      descriptors = null
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ca_instance_role" {
  name_prefix        = "${var.environment}-step-ca-ssm-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = merge(var.tags, {
    Name = "${var.environment}-step-ca-ssm-role"
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ca_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ca_instance_profile" {
  name_prefix = "${var.environment}-step-ca-profile-"
  role        = aws_iam_role.ca_instance_role.name

  tags = var.tags
}

# =============================================================================
# Optional SSH Key Pair (Break-Glass Access)
# =============================================================================

resource "aws_key_pair" "break_glass" {
  count      = var.ssh_public_key != null ? 1 : 0
  key_name   = "${var.environment}-step-ca-breakglass-key"
  public_key = var.ssh_public_key

  tags = var.tags
}

# =============================================================================
# AWS Security Group Isolation
# Strict boundary: Ports 443 (TCP), 1812 (UDP), 1813 (UDP) isolated to VPC
# =============================================================================

resource "aws_security_group" "ca_radius" {
  name_prefix = "${var.environment}-stepca-freeradius-sg-"
  description = "Isolate Step-CA and FreeRADIUS endpoints strictly to internal VPC ranges"
  vpc_id      = local.vpc_id

  # Smallstep CA HTTPS API / ACME / mTLS Endpoint
  ingress {
    description = "Step-CA TLS/HTTPS and ACME enrollment"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # FreeRADIUS Authentication Service
  ingress {
    description = "FreeRADIUS 802.1X Authentication service"
    from_port   = 1812
    to_port     = 1812
    protocol    = "udp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # FreeRADIUS Accounting Service
  ingress {
    description = "FreeRADIUS Accounting service"
    from_port   = 1813
    to_port     = 1813
    protocol    = "udp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # Optional Break-Glass SSH (only active if public key supplied)
  dynamic "ingress" {
    for_each = var.ssh_public_key != null ? [1] : []
    content {
      description = "Restricted break-glass SSH access"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.allowed_cidr_blocks
    }
  }

  # Full outbound egress to allow OS updates, Docker image pulls, and CRL distribution
  egress {
    description      = "Outbound HTTPS/DNS egress for OS package updates and Docker pulls"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.environment}-stepca-radius-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# Persistent Encrypted Storage (EBS)
# DECOUPLED LIFECYCLE: Protects root cryptographic keys from destruction
# =============================================================================

resource "aws_ebs_volume" "ca_data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.ebs_volume_size
  type              = "gp3"
  encrypted         = true
  kms_key_id        = var.kms_key_arn

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(var.tags, {
    Name        = "${var.environment}-step-ca-storage"
    Role        = "PKI-Root-Cryptographic-Keys"
    Persistence = "Decoupled"
  })
}

# =============================================================================
# MicroVM Compute Instance: AWS Graviton t4g.micro (Nitro Hypervisor)
# =============================================================================

resource "aws_instance" "ca_server" {
  ami                  = var.ami_id != null ? var.ami_id : data.aws_ami.ubuntu_arm64.id
  instance_type        = var.instance_type
  subnet_id            = local.subnet_id
  iam_instance_profile = aws_iam_instance_profile.ca_instance_profile.name

  vpc_security_group_ids = [
    aws_security_group.ca_radius.id
  ]

  key_name = var.ssh_public_key != null ? aws_key_pair.break_glass[0].key_name : null

  root_block_device {
    volume_size           = 15
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

    tags = merge(var.tags, {
      Name = "${var.environment}-step-ca-root"
    })
  }

  user_data = templatefile("${path.module}/user_data.sh", {
    ebs_volume_id = aws_ebs_volume.ca_data.id
    ca_name       = var.ca_name
    ca_dns        = var.ca_dns
    ca_password   = random_password.ca_password.result
    radius_secret = random_password.radius_secret.result
  })

  user_data_replace_on_change = false

  tags = merge(var.tags, {
    Name = "${var.environment}-step-ca-microvm"
    Role = "PKI-RADIUS-Server"
  })
}

# =============================================================================
# EBS Volume Attachment
# =============================================================================

resource "aws_volume_attachment" "ca_data_attach" {
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.ca_data.id
  instance_id  = aws_instance.ca_server.id
  force_detach = false
}
