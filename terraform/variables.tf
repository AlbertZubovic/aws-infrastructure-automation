# Inputs
variable "key_name" {
  description = "Existing EC2 key pair name"
  type = string
}

variable "private_subnet_cidrs" {
  description = "Two non overlapping /24 CIDRs inside the default VPC CIDR"
  type        = list(string)
  default     = ["172.31.200.0/24", "172.31.201.0/24"]
}

