# Instance IPs

# DB (private only)
output "db_private_ip" {
  description = "Private IPv4 address of the database EC2 instance."
  value = aws_instance.db.private_ip
}

# Backend (2 instances) - private only
output "backend_private_ips" {
  description = "Private IPv4 addresses of the backend EC2 instances."
  value = [for i in aws_instance.backend : i.private_ip]
}

# Frontend (2 instances) - public and private
output "frontend_public_ips" {
  description = "Public IPv4 addresses of the frontend EC2 instances."
  value = [for i in aws_instance.frontend : i.public_ip]
}

output "frontend_private_ips" {
  description = "Private IPv4 addresses of the frontend EC2 instances."
  value = [for i in aws_instance.frontend : i.private_ip]
}

# Convenience

output "app_url_http" {
  description = "Frontend URL."
  value = "http://${aws_lb.frontend.dns_name}"
}

# ALB DNS names
output "frontend_alb_dns" {
  description = "Public DNS name of the Frontend Application Load Balancer."
  value = aws_lb.frontend.dns_name
}

output "backend_alb_dns" {
  description = "Internal DNS name of the Backend Application Load Balancer."
  value = aws_lb.backend.dns_name
}
