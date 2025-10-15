# Per host IPs
output "db_public_ip" {
  description = "Public IPv4 address of the database EC2 instance."
  value       = aws_instance.db.public_ip
}

output "db_private_ip" {
  description = "Private IPv4 address of the database EC2 instance."
  value       = aws_instance.db.private_ip
}

output "backend_public_ip" {
  description = "Public IPv4 address of the backend EC2 instance."
  value       = aws_instance.backend[0].public_ip
}

output "backend_private_ip" {
  description = "Private IPv4 address of the backend EC2 instance."
  value       = aws_instance.backend[0].private_ip
}

output "frontend_public_ip" {
  description = "Public IPv4 address of the frontend EC2 instance."
  value       = aws_instance.frontend[0].public_ip
}

output "frontend_private_ip" {
  description = "Private IPv4 address of the frontend EC2 instance."
  value       = aws_instance.frontend[0].private_ip
}

# Convenience
output "app_url_http" {
  description = "Frontend URL."
  value       = "http://${aws_lb.frontend.dns_name}"
}

# ALB DNS names
output "frontend_alb_dns" {
    description = "Public DNS name of the Frontend Application Load Balancer"
    value = aws_lb.frontend.dns_name
}

output "backend_alb_dns" {
    description = "Internal DNS name of the Backend Application Load Balancer"
    value = aws_lb.backend.dns_name
}