# Buckets
output "scripts_bucket_name" {
  value = aws_s3_bucket.scripts.id
}

output "datalake_bucket_name" {
  value = aws_s3_bucket.datalake.id
}

# S3 URIs for test artifacts
output "lambda_producer_zip_s3_uri" {
  value = "s3://${aws_s3_bucket.scripts.bucket}/${aws_s3_object.lambda_producer_zip.key}"
}

output "lambda_processor_zip_s3_uri" {
  value = "s3://${aws_s3_bucket.scripts.bucket}/${aws_s3_object.lambda_processor_zip.key}"
}

output "common_layer_zip_s3_uri" {
  value = "s3://${aws_s3_bucket.scripts.bucket}/${aws_s3_object.common_layer_zip.key}"
}

output "glue_test_script_s3_uri" {
  value = "s3://${aws_s3_bucket.scripts.bucket}/${aws_s3_object.glue_test_script.key}"
}

# Lambda functions
output "lambda_producer_name" {
  value = aws_lambda_function.producer.function_name
}
output "lambda_producer_arn" {
  value = aws_lambda_function.producer.arn
}
output "lambda_processor_name" {
  value = aws_lambda_function.processor.function_name
}
output "lambda_processor_arn" {
  value = aws_lambda_function.processor.arn
}

# Layer
output "common_layer_arn" {
  value = aws_lambda_layer_version.common.arn
}

# SQS
output "sqs_queue_arn" {
  value = aws_sqs_queue.pipeline_queue.arn
}
output "sqs_queue_url" {
  value = aws_sqs_queue.pipeline_queue.id
}

# Glue job
output "glue_job_name" {
  value = aws_glue_job.pipeline_job.name
}
output "glue_job_arn" {
  value = aws_glue_job.pipeline_job.arn
}

# Step Functions
output "state_machine_name" {
  value = aws_sfn_state_machine.pipeline_state_machine.name
}
output "state_machine_arn" {
  value = aws_sfn_state_machine.pipeline_state_machine.arn
}
