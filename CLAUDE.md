# CLAUDE.md — Developer & Assistant Project Memory

This guide contains essential commands, architectural standards, code style guidelines, and troubleshooting workflows for developing and maintaining the Step-CA & FreeRADIUS OpenTofu codebase.

---

## 1. Essential OpenTofu CLI Commands

Always utilize OpenTofu commands (`tofu`) rather than legacy `terraform` binaries.

### Daily Development & Linting
```bash
# Format check across all files
tofu fmt -check

# Reformat code to standard HCL canonical formatting
tofu fmt

# Validate configuration syntax, variable constraints, and provider contracts
tofu validate
```

### Plan & Apply Workflow
```bash
# Initialize working directory and upgrade provider plugins
tofu init -upgrade

# Generate and save a deterministic execution plan
tofu plan -out=tfplan

# Apply the pre-inspected plan
tofu apply tfplan

# Inspect current state resources
tofu state list

# Display all output values (sensitive values masked)
tofu output

# Display sensitive credentials securely
tofu output -raw ca_password
tofu output -raw radius_secret
```

---

## 2. Code Style & HCL Architecture Guidelines

1. **Naming Conventions:**
   - **Resources & Data Sources**: Strictly `snake_case` (e.g., `aws_security_group.ca_radius`, `data.aws_ami.ubuntu_arm64`).
   - **Variables & Outputs**: Strictly `snake_case` (e.g., `ebs_volume_size`, `ca_endpoint_url`).
   - **File Structure**:
     - `providers.tf`: Provider requirements, minimum engine versions, and provider blocks.
     - `variables.tf`: All variable declarations with explicit types and descriptions.
     - `outputs.tf`: All output declarations with descriptions and `sensitive` flags where required.
     - `main.tf`: Core cloud infrastructure resources, security boundaries, and compute configurations.
     - `user_data.sh`: Standalone templated bash script managing host bootstrapping.

2. **Variable Standards:**
   - Always declare explicit types (`type = string`, `type = list(string)`, `type = number`, `type = map(string)`).
   - Never omit the `description` attribute on variables or outputs.
   - Use `validation` blocks for constrained parameters (e.g., volume sizes, CIDR validations).

3. **Security Standards:**
   - Security group ingress rules must **never** use `0.0.0.0/0` for administrative, CA, or RADIUS services. Ingress must be restricted to internal CIDR ranges (`var.allowed_cidr_blocks`).
   - Never commit `.tfvars` files containing production secrets. Keep `terraform.tfvars.example` sanitized.
   - Ensure `aws_ebs_volume` has `encrypted = true` and `prevent_destroy = true`.

4. **Tagging Policy:**
   - All AWS resources must inherit consistent default tags:
     - `Project`: "Internal-PKI-RADIUS"
     - `ManagedBy`: "OpenTofu"
     - `Environment`: Configurable via `var.environment`

---

## 3. Troubleshooting & Operational Workflows

### Scenario A: Resolving State Locks
If an OpenTofu operation is interrupted, remote state storage (e.g., AWS S3 with DynamoDB state locking) may leave a lock active, producing:
`Error: Error acquiring the state lock ... Lock Info: ID: <LOCK-ID>`

```bash
# Inspect the lock ID from the error message and release safely:
tofu force-unlock <LOCK-ID>
```
*Note: Always verify with team members that no concurrent pipeline or engineer is actively running `tofu apply` before breaking a lock.*

### Scenario B: Debugging MicroVM Cloud-Init & Container Startup
Since administrative SSH is disabled in favor of AWS Systems Manager (SSM), connect securely via the AWS CLI:

```bash
# 1. Connect to MicroVM shell via AWS SSM Session Manager
aws ssm start-session --target <INSTANCE_ID>

# 2. Tail the bootstrap script execution log
tail -f /var/log/pki-bootstrap.log

# 3. Check cloud-init system logs
cat /var/log/cloud-init-output.log | grep -E "ERROR|FATAL|Traceback"

# 4. Check status of systemd pki-radius service
systemctl status pki-radius.service

# 5. Inspect container health and logs
docker compose -f /opt/pki-radius/docker-compose.yml ps
docker compose -f /opt/pki-radius/docker-compose.yml logs -f step-ca
docker compose -f /opt/pki-radius/docker-compose.yml logs -f freeradius
```

### Scenario C: Nitro Hypervisor NVMe EBS Volume Troubleshooting
On AWS Nitro MicroVM instances (`t4g.micro`), attached EBS volumes are exposed as NVMe devices rather than `/dev/sdf`.

```bash
# List all attached NVMe block devices and identify by serial number:
nvme list

# Identify disk UUIDs and filesystem types:
blkid

# Verify that /mnt/step-ca is properly mounted to the persistent volume:
df -hT /mnt/step-ca
mountpoint /mnt/step-ca

# If step-ca container reports permission denied writing to /home/step:
# Step-CA runs under UID 1000:GID 1000
ls -ld /mnt/step-ca/step
chown -R 1000:1000 /mnt/step-ca/step
chmod 700 /mnt/step-ca/step
```
