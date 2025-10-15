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
  value       = aws_instance.backend.public_ip
}

output "backend_private_ip" {
  description = "Private IPv4 address of the backend EC2 instance."
  value       = aws_instance.backend.private_ip
}

output "frontend_public_ip" {
  description = "Public IPv4 address of the frontend EC2 instance."
  value       = aws_instance.frontend.public_ip
}

output "frontend_private_ip" {
  description = "Private IPv4 address of the frontend EC2 instance."
  value       = aws_instance.frontend.private_ip
}

# Convenience
output "app_url_http" {
  description = "Frontend URL."
  value       = "http://${aws_instance.frontend.public_ip}"
}
