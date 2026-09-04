# AnythingLLM Production Stack on AWS Graviton

This directory provisions a standalone, production-ready **AnythingLLM** instance with **Caddy** on an AWS Graviton MicroVM (`t4g.small`), complete with decoupled encrypted EBS storage for vector embeddings and document persistence.

---

## Architectural Highlights

- **Compute**: AWS EC2 `t4g.small` (2 vCPU, 2 GiB RAM, 64-bit ARM Graviton) running Ubuntu 24.04 LTS Minimal.
- **Persistence**: Decoupled, KMS-encrypted **20 GiB EBS volume (`gp3`)** mounted at `/mnt/anythingllm` to store vector databases (LanceDB), SQLite database, and documents.
- **Reverse Proxy**: Caddy reverse proxy handling ports 80/443 with automatic TLS certificate provisioning.
- **Zero-Trust Management**: Managed via AWS Systems Manager (SSM) Session Manager without requiring open SSH port 22.
- **Static Public IP**: Bound to an AWS Elastic IP (EIP) so the public address never changes across reboots or rebuilds.

---

## Quick Start

### 1. Review / Customize Variables
```bash
cd anythingllm
cp terraform.tfvars.example terraform.tfvars
```

### 2. Deploy
```bash
tofu plan
tofu apply
```

### 3. Access AnythingLLM
Once applied, OpenTofu outputs the static public IP:
```bash
tofu output anythingllm_url
```

Open `http://<PUBLIC_IP>` in your browser. The initial setup wizard will guide you to:
1. Set up your administrator password.
2. Enable Multi-User Mode so team members can create accounts.
3. Configure your LLM provider (OpenAI, Anthropic, Bedrock, or local models).
