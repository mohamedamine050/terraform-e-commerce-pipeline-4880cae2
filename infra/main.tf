
# ─────────────────────────────────────────────────────────────────────────────
# Remote backend — state stored in S3, locking via DynamoDB
# (Provisioned by the bootstrap/ folder)
# ─────────────────────────────────────────────────────────────────────────────
terraform {
  backend "s3" {
    bucket         = "tfstate-e-commerce-pipeline-u0op6129"
    key            = "infra/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tflock-e-commerce-pipeline-u0op6129"
    encrypt        = true
  }
}

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --------------------------------------------------------------------
# Random suffix for naming
# --------------------------------------------------------------------
resource "random_string" "suffix" {
  length  = 16
  lower   = true
  upper   = false
  numeric = true
  special = false
}

# --------------------------------------------------------------------
# S3 Buckets
# --------------------------------------------------------------------
resource "aws_s3_bucket" "scripts" {
  bucket        = "pipeline-scripts-${random_string.suffix.result}"
  force_destroy = true
}

resource "aws_s3_bucket" "datalake" {
  bucket        = "pipeline-datalake-${random_string.suffix.result}"
  force_destroy = true
}

# --------------------------------------------------------------------
# Layer code (common)
# --------------------------------------------------------------------
resource "local_file" "common_layer_code" {
  filename = "${path.module}/layer/python/common.py"
  content  = <<-EOF
def helper():
    return "Hello from TEST layer"
EOF
}

resource "local_file" "common_layer_init" {
  filename = "${path.module}/layer/python/__init__.py"
  content  = ""
}

# placeholder to ensure the ./layer directory exists for archive_file
resource "local_file" "layer_placeholder" {
  filename = "${path.module}/layer/placeholder.txt"
  content  = ""
}

data "archive_file" "common_layer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/layer"
  output_path = "${path.module}/dist/common_layer.zip"
  depends_on = [
    local_file.common_layer_code,
    local_file.common_layer_init,
    local_file.layer_placeholder
  ]
}

resource "aws_s3_object" "common_layer_zip" {
  bucket = aws_s3_bucket.scripts.id
  key    = "layer/common_layer.zip"
  source = data.archive_file.common_layer_zip.output_path
  etag   = data.archive_file.common_layer_zip.output_md5
}

resource "aws_lambda_layer_version" "common" {
  layer_name          = "common-layer-${random_string.suffix.result}"
  s3_bucket           = aws_s3_bucket.scripts.id
  s3_key              = aws_s3_object.common_layer_zip.key
  compatible_runtimes = ["python3.9"]
  source_code_hash    = data.archive_file.common_layer_zip.output_base64sha256
  depends_on          = [aws_s3_object.common_layer_zip]
}

# --------------------------------------------------------------------
# Lambda Producer
# --------------------------------------------------------------------
resource "local_file" "lambda_producer_code" {
  filename = "${path.module}/src/producer_lambda.py"
  content  = <<-EOF
import json, boto3, os
sqs = boto3.client('sqs')
def lambda_handler(event, context):
    message = {"msg": "test record"}
    sqs.send_message(
        QueueUrl=os.environ['SQS_URL'],
        MessageBody=json.dumps(message)
    )
    return {"statusCode": 200, "body": "sent"}
EOF
}

data "archive_file" "lambda_producer_zip" {
  type        = "zip"
  source_file = local_file.lambda_producer_code.filename
  output_path = "${path.module}/dist/producer_lambda.zip"
}

resource "aws_s3_object" "lambda_producer_zip" {
  bucket = aws_s3_bucket.scripts.id
  key    = "lambda/producer_lambda.zip"
  source = data.archive_file.lambda_producer_zip.output_path
  etag   = data.archive_file.lambda_producer_zip.output_md5
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_producer_role" {
  name               = "lambda-producer-role-${random_string.suffix.result}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_producer_basic" {
  role       = aws_iam_role.lambda_producer_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_producer_admin" {
  role       = aws_iam_role.lambda_producer_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_lambda_function" "producer" {
  function_name    = "lambda-producer-${random_string.suffix.result}"
  s3_bucket        = aws_s3_bucket.scripts.id
  s3_key           = aws_s3_object.lambda_producer_zip.key
  source_code_hash = data.archive_file.lambda_producer_zip.output_base64sha256
  handler          = "producer_lambda.lambda_handler"
  runtime          = "python3.9"
  timeout          = 30
  memory_size      = 256
  role             = aws_iam_role.lambda_producer_role.arn
  layers           = [aws_lambda_layer_version.common.arn]
  environment {
    variables = {
      SQS_URL = aws_sqs_queue.pipeline_queue.id
    }
  }
  depends_on = [
    aws_s3_object.lambda_producer_zip,
    aws_lambda_layer_version.common,
    aws_iam_role_policy_attachment.lambda_producer_basic,
    aws_iam_role_policy_attachment.lambda_producer_admin
  ]
}

# --------------------------------------------------------------------
# Lambda Processor
# --------------------------------------------------------------------
resource "local_file" "lambda_processor_code" {
  filename = "${path.module}/src/processor_lambda.py"
  content  = <<-EOF
import json, boto3, os
s3 = boto3.client('s3')
def lambda_handler(event, context):
    for record in event['Records']:
        body = json.loads(record['body'])
        s3.put_object(
            Bucket=os.environ['RAW_BUCKET'],
            Key='raw/' + record['messageId'] + '.json',
            Body=json.dumps(body)
        )
    return {"statusCode": 200, "body": "processed"}
EOF
}

data "archive_file" "lambda_processor_zip" {
  type        = "zip"
  source_file = local_file.lambda_processor_code.filename
  output_path = "${path.module}/dist/processor_lambda.zip"
}

resource "aws_s3_object" "lambda_processor_zip" {
  bucket = aws_s3_bucket.scripts.id
  key    = "lambda/processor_lambda.zip"
  source = data.archive_file.lambda_processor_zip.output_path
  etag   = data.archive_file.lambda_processor_zip.output_md5
}

resource "aws_iam_role" "lambda_processor_role" {
  name               = "lambda-processor-role-${random_string.suffix.result}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_processor_basic" {
  role       = aws_iam_role.lambda_processor_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_processor_admin" {
  role       = aws_iam_role.lambda_processor_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_lambda_function" "processor" {
  function_name    = "lambda-processor-${random_string.suffix.result}"
  s3_bucket        = aws_s3_bucket.scripts.id
  s3_key           = aws_s3_object.lambda_processor_zip.key
  source_code_hash = data.archive_file.lambda_processor_zip.output_base64sha256
  handler          = "processor_lambda.lambda_handler"
  runtime          = "python3.9"
  timeout          = 30
  memory_size      = 256
  role             = aws_iam_role.lambda_processor_role.arn
  layers           = [aws_lambda_layer_version.common.arn]
  environment {
    variables = {
      RAW_BUCKET = aws_s3_bucket.scripts.id
    }
  }
  depends_on = [
    aws_s3_object.lambda_processor_zip,
    aws_lambda_layer_version.common,
    aws_iam_role_policy_attachment.lambda_processor_basic,
    aws_iam_role_policy_attachment.lambda_processor_admin
  ]
}

# --------------------------------------------------------------------
# SQS Queue
# --------------------------------------------------------------------
resource "aws_sqs_queue" "pipeline_queue" {
  name = "pipeline-queue-${random_string.suffix.result}"
}

# --------------------------------------------------------------------
# Glue Job
# --------------------------------------------------------------------
resource "local_file" "glue_test_script" {
  filename = "${path.module}/glue_scripts/test_glue_job.py"
  content  = <<-EOF
import sys
print("Hello from TEST Glue script")
EOF
}

resource "aws_s3_object" "glue_test_script" {
  bucket     = aws_s3_bucket.scripts.id
  key        = "glue_scripts/test_glue_job.py"
  source     = local_file.glue_test_script.filename
  depends_on = [local_file.glue_test_script]
}

data "aws_iam_policy_document" "glue_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_role" {
  name               = "glue-role-${random_string.suffix.result}"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy_attachment" "glue_admin" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_glue_job" "pipeline_job" {
  name         = "glue-job-${random_string.suffix.result}"
  role_arn     = aws_iam_role.glue_role.arn
  glue_version = "4.0"
  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.scripts.bucket}/${aws_s3_object.glue_test_script.key}"
    python_version  = "3"
  }
  default_arguments = {
    "--TempDir"      = "s3://${aws_s3_bucket.scripts.bucket}/temp/"
    "--job-language" = "python"
  }
  max_capacity = 2
  depends_on = [
    aws_iam_role_policy_attachment.glue_service,
    aws_iam_role_policy_attachment.glue_admin,
    aws_s3_object.glue_test_script
  ]
}

# --------------------------------------------------------------------
# Step Functions State Machine
# --------------------------------------------------------------------
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "step_functions_role" {
  name               = "step-functions-role-${random_string.suffix.result}"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

resource "aws_iam_role_policy_attachment" "sfn_full" {
  role       = aws_iam_role.step_functions_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSStepFunctionsFullAccess"
}

resource "aws_iam_role_policy_attachment" "sfn_admin" {
  role       = aws_iam_role.step_functions_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_sfn_state_machine" "pipeline_state_machine" {
  name     = "state-machine-${random_string.suffix.result}"
  role_arn = aws_iam_role.step_functions_role.arn

  definition = jsonencode({
    Comment = "Pipeline orchestrator"
    StartAt = "InvokeProducer"

    States = {
      InvokeProducer = {
        Type     = "Task"
        Resource = aws_lambda_function.producer.arn
        Next     = "WaitForMessages"
      }

      WaitForMessages = {
        Type     = "Wait"
        Seconds  = 10
        Next     = "InvokeProcessor"
      }

      InvokeProcessor = {
        Type     = "Task"
        Resource = aws_lambda_function.processor.arn
        Next     = "StartGlueJob"
      }

      StartGlueJob = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"

        Parameters = {
          JobName = aws_glue_job.pipeline_job.name

          Arguments = {
            "--CONFIG_PATH"    = "s3://tfstate-e-commerce-pipeline-u0op6129/config.json"
          }
        }

        End = true
      }
    }
  })

  depends_on = [
    aws_iam_role_policy_attachment.sfn_full,
    aws_iam_role_policy_attachment.sfn_admin,
    aws_lambda_function.producer,
    aws_lambda_function.processor,
    aws_glue_job.pipeline_job
  ]
}

resource "aws_lambda_event_source_mapping" "processor_sqs" {
  event_source_arn = aws_sqs_queue.pipeline_queue.arn
  function_name    = aws_lambda_function.processor.arn

  enabled    = true
  batch_size = 10

  function_response_types = [
    "ReportBatchItemFailures"
  ]
}
