terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Partial backend config: bucket/region/dynamodb_table are shared across all
  # environments, but `key` differs per environment so each gets an isolated
  # state file. Supply `key` at `terraform init` time via -backend-config,
  # e.g.: terraform init -backend-config=environments/backend-dev.hcl
  backend "s3" {
    bucket         = "jinseo-tf-state-aws-self-healing-infra"
    region         = "ap-southeast-1"
    dynamodb_table = "terraform-lock-aws-self-healing-infra"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
