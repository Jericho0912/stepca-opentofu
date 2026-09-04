# =============================================================================
# Network Resolution
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
# AMI Discovery: Ubuntu 24.04 LTS Minimal (ARM64 Graviton)
# =============================================================================

data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

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
# =============================================================================

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "anythingllm_role" {
  name_prefix        = "${var.environment}-anythingllm-ssm-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = merge(var.tags, {
    Name = "${var.environment}-anythingllm-ssm-role"
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.anythingllm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "anythingllm_profile" {
  name_prefix = "${var.environment}-anythingllm-profile-"
  role        = aws_iam_role.anythingllm_role.name

  tags = var.tags
}

# =============================================================================
# Security Group Isolation
# =============================================================================

resource "aws_security_group" "anythingllm_sg" {
  name_prefix = "${var.environment}-anythingllm-sg-"
  description = "Security group for AnythingLLM Web UI and Caddy reverse proxy"
  vpc_id      = local.vpc_id

  # HTTP (Port 80)
  ingress {
    description = "HTTP web access (redirected to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_ingress_cidrs
  }

  # HTTPS (Port 443)
  ingress {
    description = "HTTPS AnythingLLM Web interface"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_ingress_cidrs
  }

  # Outbound egress for downloading AI models and Docker images
  egress {
    description      = "Outbound HTTPS/DNS egress"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.environment}-anythingllm-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# Persistent Encrypted Storage (EBS)
# Stores user accounts, vector embeddings, and uploaded documents
# =============================================================================

resource "aws_ebs_volume" "anythingllm_data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.ebs_volume_size
  type              = "gp3"
  encrypted         = true

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(var.tags, {
    Name        = "${var.environment}-anythingllm-storage"
    Role        = "VectorDB-Document-Storage"
    Persistence = "Decoupled"
  })
}

# =============================================================================
# Compute Instance: AWS Graviton t4g.small (Nitro Hypervisor)
# =============================================================================

resource "aws_instance" "anythingllm_server" {
  ami                  = data.aws_ami.ubuntu_arm64.id
  instance_type        = var.instance_type
  subnet_id            = local.subnet_id
  iam_instance_profile = aws_iam_instance_profile.anythingllm_profile.name

  vpc_security_group_ids = [
    aws_security_group.anythingllm_sg.id
  ]

  root_block_device {
    volume_size           = 15
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

    tags = merge(var.tags, {
      Name = "${var.environment}-anythingllm-root"
    })
  }

  user_data = templatefile("${path.module}/user_data.sh", {
    ebs_volume_id = aws_ebs_volume.anythingllm_data.id
    domain_name   = var.domain_name != null ? var.domain_name : ""
  })

  user_data_replace_on_change = false

  tags = merge(var.tags, {
    Name = "${var.environment}-anythingllm-server"
    Role = "AnythingLLM-Host"
  })
}

# =============================================================================
# EBS Volume Attachment
# =============================================================================

resource "aws_volume_attachment" "anythingllm_attach" {
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.anythingllm_data.id
  instance_id  = aws_instance.anythingllm_server.id
  force_detach = false
}

# =============================================================================
# Static Elastic IP (Public Access)
# Guarantees the public IP never changes if the instance is rebooted or rebuilt
# =============================================================================

resource "aws_eip" "anythingllm_ip" {
  domain   = "vpc"
  instance = aws_instance.anythingllm_server.id

  tags = merge(var.tags, {
    Name = "${var.environment}-anythingllm-eip"
  })
}
