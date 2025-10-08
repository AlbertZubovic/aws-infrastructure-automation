# Outputs
output "app_public_ip"  { value = aws_instance.app.public_ip }
output "app_public_dns" { value = aws_instance.app.public_dns }
output "ssh_connect"    { value = "ssh -i a2-key.pem ec2-user@${aws_instance.app.public_ip}" }
