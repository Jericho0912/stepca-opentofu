# AGENTS.md — Operational Constraints & System Instructions for AI Agents

> **Scope**: This document defines the operational scope, architectural constraints, and safety guidelines for any autonomous agent or automated LLM assistant modifying or maintaining this codebase.

---

## 1. Technical Stack Overview

This repository provisions a production-grade, low-touch **Private Certificate Authority (CA)** and **RADIUS Server** stack designed for managing internal environment mTLS/HTTPS certificates and future 802.1X EAP-TLS Wi-Fi network authentication.

| Component | Technology | Specification / Role |
| :--- | :--- | :--- |
| **IaC Engine** | OpenTofu `>= 1.6.0` | Declarative cloud infrastructure orchestrator using OpenTofu registry |
| **Providers** | `hashicorp/aws (~> 5.0)`, `hashicorp/random (~> 3.6)` | Cloud compute/storage orchestration and cryptographic secret generation |
| **Compute / MicroVM** | AWS EC2 `t4g.micro` | AWS Graviton2 (64-bit ARM) secured by the Nitro hardware-isolated hypervisor |
| **Operating System** | Ubuntu 24.04 LTS Minimal (ARM64) | Minimal attack surface, systemd-managed, official Canonical Noble minimal AMI |
| **Storage Persistence** | AWS EBS `gp3` (10 GiB, Encrypted) | Decoupled volume hosting root keys, intermediate certificates, and CA DB |
| **Zero-Trust Access** | AWS Systems Manager (SSM) | Instance profile with `AmazonSSMManagedInstanceCore`; no inbound SSH port 22 needed |
| **Container Engine** | Docker CE + Docker Compose Plugin | Installed dynamically via cloud-init/user-data with `qemu-user-static` |
| **CA Service** | `smallstep/step-ca:latest` | Automated PKI, ACME, and mTLS endpoints exposed on host port 443 |
| **RADIUS Service** | `freeradius/freeradius-server:latest` | Network Access Control (802.1X EAP-TLS) listening on UDP 1812 & 1813 |

---

## 2. The Cardinal Rule: Absolute Key Persistence

### ⚠️ NON-NEGOTIABLE OPERATIONAL RULE
**NEVER MODIFY, TAINT, OR DESTROY THE PERSISTENT EBS VOLUME (`aws_ebs_volume.ca_data`).**

```hcl
# In main.tf - THIS BLOCK MUST NEVER BE REMOVED OR BYPASSED
lifecycle {
  prevent_destroy = true
}
```

### Cryptographic Justification:
The root private key (`/mnt/step-ca/step/secrets/root_ca_key`), intermediate signing keys, the Step-CA embedded Badger database, and FreeRADIUS certificates reside on this 10 GiB EBS volume.
- **Destructive impact of volume replacement:**
  1. Instant loss of the root cryptographic trust anchor.
  2. Complete invalidation of all existing certificates across all 10 internal tools.
  3. Total outage of mutual TLS (mTLS) services and staging ingress controllers.
  4. Permanent lockout of Wi-Fi clients authenticating via 802.1X / EAP-TLS.
- **Permitted Compute Operations:**
  The EC2 instance (`aws_instance.ca_server`) is intentionally **ephemeral**. You MAY destroy, upgrade, or re-provision the EC2 instance (e.g., changing AMIs, instance sizing, or security updates). The `user_data.sh` script automatically inspects the block device with `blkid`:
  - If an existing `ext4` filesystem is found, formatting is **strictly bypassed**.
  - The volume is mounted to `/mnt/step-ca`, restoring existing keys and certificates without data loss.

---

## 3. Variable Injection Protocol

Variables must **NEVER** be hardcoded into `.tf` resource files. Agents must adhere to the following priority hierarchy when configuring inputs:

### Permitted Variable Input Mechanisms:
1. **File-based Definition (Local / Development):**
   Copy `terraform.tfvars.example` to `terraform.tfvars` and edit values.
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```
2. **Environment Variable Injection (CI/CD Pipelines):**
   Prefix variable names with `TF_VAR_`:
   ```bash
   export TF_VAR_aws_region="us-west-2"
   export TF_VAR_environment="staging"
   export TF_VAR_allowed_cidr_blocks='["10.50.0.0/16"]'
   ```
3. **Explicit Variable Files (Multi-Environment):**
   ```bash
   tofu plan -var-file="environments/prod.tfvars" -out=prod.tfplan
   ```

### Constraints:
- Every variable defined in `variables.tf` must include explicit `type`, `description`, and appropriate `default` or `validation` blocks.
- Passwords and secrets generated via `random_password` must be marked `sensitive = true` in `outputs.tf`.
- Never expose `ca_password` or `radius_secret` in plaintext stdout during CI agent runs.

---

## 4. Agent Execution Safety Protocol

Before proposing or executing any infrastructure mutations, agents must execute the following sequential checklist:

1. **Linting & Code Formatting:**
   ```bash
   tofu fmt -check
   ```
   If formatting errors exist, run `tofu fmt` before creating a pull request.

2. **Static Configuration Validation:**
   ```bash
   tofu validate
   ```
   Ensure zero syntax or provider compatibility errors.

3. **Plan Inspection & Blast Radius Analysis:**
   ```bash
   tofu plan -out=tfplan
   ```
   Agents MUST analyze the plan output:
   - Green `+` (Create): Verify parameters match requirements.
   - Yellow `~` (Update in-place): Safe for non-destructive updates.
   - Red `-` / `+` (Replace): **CRITICAL**. Verify that `aws_ebs_volume.ca_data` is NOT marked for replacement (`# aws_ebs_volume.ca_data must be replaced`). If it is, ABORT IMMEDIATELY and investigate the attribute causing replacement (e.g., `availability_zone` drift).

4. **Nitro Hypervisor & NVMe Block Mapping Verification:**
   When altering `user_data.sh`, agents must preserve the dynamic NVMe block device discovery logic. On AWS Nitro microVMs (`t4g.micro`), EBS volumes appear as NVMe devices (`/dev/nvme*n1` or `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_*`), NOT traditional `/dev/sdf` kernel handles.

5. **Container Architecture Awareness:**
   The target architecture is **ARM64 (Graviton)**. Any additional Docker containers added to `docker-compose.yml` must either provide native `linux/arm64` images or utilize the pre-installed `qemu-user-static` binfmt translation layer.
