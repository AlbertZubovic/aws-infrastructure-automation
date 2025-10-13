# Outputs
output "app_public_ip" {
    value = aws_instance.app.public_ip
    description = "Public IP of the EC2 instance"
}

output "app_public_dns" {
    value = aws_instance.app.public_dns
    description = "Public DNS of the EC2 instance"
}

output "app_url_http" {
    value = "http://${aws_instance.app.public_ip}"
    description = "HTTP URL to the app"
}

output "ssh_connect" {
    value = "ssh -i a2-key.pem ec2-user@${aws_instance.app.public_ip}"
    description = "Convenience SSH command"
}

