output "state_bucket" {
  value       = aws_s3_bucket.tf_state.bucket
  description = "S3 bucket used for Terraform remote state"
}

output "state_bucket_arn" {
  value       = aws_s3_bucket.tf_state.arn
  description = "ARN of the state bucket"
}

output "state_lock_table" {
  value       = aws_dynamodb_table.tf_locks.name
  description = "DynamoDB table used for Terraform state locking"
}

output "state_lock_table_arn" {
  value       = aws_dynamodb_table.tf_locks.arn
  description = "ARN of the lock table"
}
