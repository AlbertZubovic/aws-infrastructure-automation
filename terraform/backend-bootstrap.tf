# Run once with local backend, then switch Terraform to use the S3 backend.

variable "state_bucket_name" {
  description = "unique S3 bucket name for Terraform state"
  type = string
}

variable "state_table_name" {
  description = "DynamoDB table name for Terraform state locking"
  type        = string
  default     = "a2-tf-locks"
}

# S3 bucket for state
resource "aws_s3_bucket" "tf_state" {
  bucket = var.state_bucket_name
}

# Block public access
resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning
resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration { status = "Enabled" }
}

# Server side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# DynamoDB table for state locking
resource "aws_dynamodb_table" "tf_locks" {
  name         = var.state_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "state_bucket" { value = aws_s3_bucket.tf_state.bucket }
output "state_lock_table" { value = aws_dynamodb_table.tf_locks.name }
