variable "aws_region" {
  description = "AWS region for bootstrap resources"
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Unique S3 bucket name for Terraform state"
  type        = string
}

variable "state_table_name" {
  description = "DynamoDB table name for Terraform state locking"
  type        = string
  default     = "tf-locks"
}

variable "force_destroy" {
  description = "Allow destroy to empty and delete the state bucket"
  type        = bool
  default     = false
}
