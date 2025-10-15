terraform {
  backend "s3" {
    bucket         = "a2-tf-state-s4007755"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "a2-tf-locks-s4007755"
    encrypt        = true
  }
}
