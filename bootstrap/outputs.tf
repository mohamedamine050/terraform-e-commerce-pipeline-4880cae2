output "s3_bucket_name" {
  description = "Name of the S3 bucket storing Terraform state"
  value       = aws_s3_bucket.tfstate.id
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table used for state locking"
  value       = aws_dynamodb_table.tflock.name
}

output "aws_region" {
  description = "AWS region where backend resources are deployed"
  value       = var.aws_region
}
