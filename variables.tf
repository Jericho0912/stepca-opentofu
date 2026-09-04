# -----------------------------------------------------------------------------
# Core AWS Infrastructure Variables
# -----------------------------------------------------------------------------

variable "aws_region" {
  type        = string
  description = "The AWS region where PKI resources will be provisioned."
  default     = "us-east-1"
}

variable "aws_profile" {
  type        = string
  description = "Optional AWS named profile (from ~/.aws/credentials) to authenticate with."
  default     = null
}

variable "environment" {
  type        = string
  description = "Environment name (e.g., prod, staging, dev) used for resource naming and tagging."
  default     = "prod"
}

variable "vpc_id" {
  type        = string
  description = "Target AWS VPC ID. If set to null, the default VPC in the region will be used automatically."
  default     = null
}

variable "subnet_id" {
  type        = string
  description = "Target Subnet ID within the VPC. If set to null, a default subnet from the chosen VPC will be selected."
  default     = null
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  description = "List of internal VPC/VPN CIDR blocks allowed to access Step-CA (TCP 443) and FreeRADIUS (UDP 1812/1813)."
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

# -----------------------------------------------------------------------------
# Compute & Nitro MicroVM Configuration
# -----------------------------------------------------------------------------

variable "instance_type" {
  type        = string
  description = "EC2 instance type utilizing the AWS Nitro hypervisor architecture. Defaults to Graviton t4g.micro."
  default     = "t4g.micro"
}

variable "ami_id" {
  type        = string
  description = "Optional custom AMI ID. If null, the latest official Ubuntu 24.04 LTS Noble Minimal ARM64 AMI will be looked up."
  default     = null
}

variable "ssh_public_key" {
  type        = string
  description = "Optional SSH public key for break-glass EC2 access. If omitted, AWS Systems Manager (SSM) Session Manager is used exclusively."
  default     = null
}

# -----------------------------------------------------------------------------
# Cryptographic Storage & Persistence
# -----------------------------------------------------------------------------

variable "ebs_volume_size" {
  type        = number
  description = "Size of the persistent EBS volume in GiB storing Step-CA root keys and database."
  default     = 10

  validation {
    condition     = var.ebs_volume_size >= 10
    error_message = "The EBS volume must be at least 10 GiB to guarantee adequate IOPS and long-term storage."
  }
}

variable "kms_key_arn" {
  type        = string
  description = "Optional ARN of a customer-managed KMS key (CMK) used to encrypt the persistent EBS volume. If null, the default AWS EBS key is used."
  default     = null
}

# -----------------------------------------------------------------------------
# Certificate Authority & FreeRADIUS Parameters
# -----------------------------------------------------------------------------

variable "ca_name" {
  type        = string
  description = "Human-readable name for the internal Certificate Authority."
  default     = "Internal Staging & Tooling Root CA"
}

variable "ca_dns" {
  type        = string
  description = "Primary DNS name or SAN for Step-CA (e.g., ca.internal.lan or IP address)."
  default     = "ca.internal.lan"
}

variable "tags" {
  type        = map(string)
  description = "Resource tags applied to all provisioned infrastructure components."
  default = {
    Project     = "Internal-PKI-RADIUS"
    ManagedBy   = "OpenTofu"
    Environment = "prod"
    Role        = "Security-Infrastructure"
  }
}
