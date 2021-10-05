terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.59.0"
    }
  }

  required_version = ">= 1.0.7"
}

provider "aws" {
  region = "ap-northeast-1"

  access_key = "mock"
  secret_key = "mock"

  s3_force_path_style         = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    sqs = "http://localstack:4566"
  }
}

resource "aws_sqs_queue" "messages_queue" {
  name                        = "message-queue.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
}