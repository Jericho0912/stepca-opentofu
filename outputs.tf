# =============================================================================
# Sensitive Cryptographic Credentials
# =============================================================================

output "ca_password" {
  description = "Auto-generated master password protecting the Step-CA root cryptographic keys."
  value       = random_password.ca_password.result
  sensitive   = true
}

output "radius_secret" {
  description = "Auto-generated pre-shared secret for FreeRADIUS clients (Access Points)."
  value       = random_password.radius_secret.result
  sensitive   = true
}

# =============================================================================
# Network Endpoints & Identifiers
# =============================================================================

output "ca_endpoint_url" {
  description = "HTTPS endpoint URL for Step-CA (port 443)."
  value       = "https://${var.ca_dns}"
}

output "instance_id" {
  description = "AWS EC2 MicroVM Instance ID."
  value       = aws_instance.ca_server.id
}

output "instance_private_ip" {
  description = "Private IP address of the MicroVM within the VPC."
  value       = aws_instance.ca_server.private_ip
}

output "ebs_volume_id" {
  description = "Decoupled AWS EBS Volume ID storing the persistent PKI root cryptographic keys."
  value       = aws_ebs_volume.ca_data.id
}

output "security_group_id" {
  description = "ID of the Security Group isolating the CA and RADIUS traffic."
  value       = aws_security_group.ca_radius.id
}

# =============================================================================
# Operational Quick-Start Commands
# =============================================================================

output "ssm_session_command" {
  description = "AWS Systems Manager (SSM) CLI command to securely start a console session on the MicroVM without SSH."
  value       = "aws ssm start-session --target ${aws_instance.ca_server.id}"
}

output "bootstrap_instructions" {
  description = "Step-by-step guidance to retrieve CA fingerprint and initialize local step CLI."
  value       = <<-EOT
    1. Retrieve Root CA Password:
       tofu output -raw ca_password

    2. Retrieve FreeRADIUS Shared Secret:
       tofu output -raw radius_secret

    3. Extract Root Fingerprint via SSM:
       aws ssm start-session --target ${aws_instance.ca_server.id} \
         --document-name AWS-StartInteractiveCommand \
         --parameters command="docker exec step-ca step certificate fingerprint /home/step/certs/root_ca.crt"

    4. Bootstrap Local Step CLI Client:
       step ca bootstrap --ca-url https://${aws_instance.ca_server.private_ip} --fingerprint <ROOT_FINGERPRINT> --install

    5. Monitor Cloud-Init Logs:
       aws ssm start-session --target ${aws_instance.ca_server.id} \
         --document-name AWS-StartInteractiveCommand \
         --parameters command="tail -f /var/log/pki-bootstrap.log"
  EOT
}
