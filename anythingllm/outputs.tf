# =============================================================================
# AnythingLLM Access Endpoints
# =============================================================================

output "public_ip" {
  description = "Static Elastic IP (EIP) assigned to the AnythingLLM instance."
  value       = aws_eip.anythingllm_ip.public_ip
}

output "anythingllm_url" {
  description = "Direct web URL to access AnythingLLM in your browser."
  value       = var.domain_name != null ? "https://${var.domain_name}" : "http://${aws_eip.anythingllm_ip.public_ip} (or https://${aws_eip.anythingllm_ip.public_ip})"
}

output "instance_id" {
  description = "EC2 Instance ID."
  value       = aws_instance.anythingllm_server.id
}

output "ebs_volume_id" {
  description = "Persistent EBS Volume ID storing vector embeddings and uploaded documents."
  value       = aws_ebs_volume.anythingllm_data.id
}

output "ssm_session_command" {
  description = "AWS SSM command to securely open a shell on the AnythingLLM server without SSH."
  value       = "aws ssm start-session --profile ${var.aws_profile} --region ${var.aws_region} --target ${aws_instance.anythingllm_server.id}"
}

output "initial_setup_instructions" {
  description = "Next steps to complete AnythingLLM admin onboarding."
  value       = <<-EOT
    1. Wait ~2 minutes after 'tofu apply' for Docker to pull the AnythingLLM image and start.
    2. Open your browser to:
       ${var.domain_name != null ? "https://${var.domain_name}" : "http://${aws_eip.anythingllm_ip.public_ip}"}
    3. The first visitor will be greeted with the AnythingLLM Setup Wizard:
       - Set your Admin password.
       - Enable Multi-User Mode so your team members can create accounts.
       - Connect your LLM provider (OpenAI API key, Anthropic, Ollama, or AWS Bedrock).
    4. To view container startup progress in real time:
       aws ssm start-session --profile ${var.aws_profile} --region ${var.aws_region} --target ${aws_instance.anythingllm_server.id} \
         --document-name AWS-StartInteractiveCommand \
         --parameters command="docker compose -f /opt/anythingllm/docker-compose.yml logs -f"
  EOT
}
