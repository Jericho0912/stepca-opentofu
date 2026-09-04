# -----------------------------------------------------------------------------
# AWS Environment & Authentication
# -----------------------------------------------------------------------------

variable "aws_region" {
  type        = string
  description = "The AWS region where AnythingLLM will be deployed."
  default     = "ap-southeast-1"
}

variable "aws_profile" {
  type        = string
  description = "The AWS CLI named profile to authenticate with."
  default     = "swarm"
}

variable "environment" {
  type        = string
  description = "Environment tag (e.g. dev, prod)."
  default     = "dev"
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "vpc_id" {
  type        = string
  description = "Target AWS VPC ID. Defaults to the default VPC if null."
  default     = null
}

variable "subnet_id" {
  type        = string
  description = "Target Subnet ID within the VPC. Defaults to the first default subnet if null."
  default     = null
}

variable "allowed_ingress_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to access the AnythingLLM web interface (ports 80 & 443). Defaults to 0.0.0.0/0 for internet team access."
  default     = ["0.0.0.0/0"]
}

variable "domain_name" {
  type        = string
  description = "Optional custom domain name pointing to this server (e.g. ai.company.com). If provided, Caddy automatically provisions a free Let's Encrypt certificate."
  default     = null
}

# -----------------------------------------------------------------------------
# Compute & Persistence
# -----------------------------------------------------------------------------

variable "instance_type" {
  type        = string
  description = "EC2 instance size utilizing AWS Graviton (Nitro). Defaults to t4g.small (2 vCPU, 2 GB RAM)."
  default     = "t4g.small"
}

variable "ebs_volume_size" {
  type        = number
  description = "Size in GiB of the encrypted persistent volume storing AnythingLLM documents and vector database."
  default     = 20

  validation {
    condition     = var.ebs_volume_size >= 10
    error_message = "The EBS volume must be at least 10 GiB to store documents, vector embeddings, and models."
  }
}

variable "tags" {
  type        = map(string)
  description = "Resource tags applied to all provisioned infrastructure components."
  default = {
    Project     = "AnythingLLM-Stack"
    ManagedBy   = "OpenTofu"
    Environment = "dev"
    Service     = "AI-Knowledge-Base"
  }
}
