# ─────────────────────────────────────────────────────────────────────────────
# Bootstrap — S3 bucket + DynamoDB for Terraform remote state
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region     = var.aws_region
}

# ── S3 bucket for tfstate ─────────────────────────────────────────────────────

resource "aws_s3_bucket" "tfstate" {
  bucket = "tfstate-e-commerce-pipeline-u0op6129"
  force_destroy = true
  tags = {
    Name        = "tfstate-e-commerce-pipeline-u0op6129"
    ManagedBy   = "terraform-bootstrap"
    Project     = "e-commerce-pipeline"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── DynamoDB table for state locking ──────────────────────────────────────────

resource "aws_dynamodb_table" "tflock" {
  name         = "tflock-e-commerce-pipeline-u0op6129"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = "tflock-e-commerce-pipeline-u0op6129"
    ManagedBy   = "terraform-bootstrap"
    Project     = "e-commerce-pipeline"
  }
}
