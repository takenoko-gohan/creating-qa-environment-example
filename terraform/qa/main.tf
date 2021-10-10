terraform {
  backend "s3" {
    key                  = "terraform.tfstate"
    region               = "ap-northeast-1"
    workspace_key_prefix = "qa"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.59.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1.0"
    }
    mysql = {
      source  = "winebarrel/mysql"
      version = "~> 1.10.6"
    }
  }

  required_version = ">= 1.0.7"
}

provider "aws" {
  region = "ap-northeast-1"
}

provider "random" {}

provider "mysql" {
  endpoint = "${aws_rds_cluster.cluster.endpoint}:3306"
  username = "root"
  password = random_password.root_pass.result
}

locals {
  prefix = "qa-${terraform.workspace}"
}

// remote state
data "terraform_remote_state" "common" {
  backend = "s3"
  config = {
    bucket = var.qa_common_tfstate_bucket
    key    = "qa_common/terraform.tfstate"
    region = "ap-northeast-1"
  }
}

// Security Group
resource "aws_security_group" "ecs_task" {
  name        = "${local.prefix}-ecs-task"
  description = "Security group for ECS Task"
  vpc_id      = data.terraform_remote_state.common.outputs.vpc_id
  ingress = [
    {
      cidr_blocks      = []
      ipv6_cidr_blocks = []
      security_groups = [
        data.terraform_remote_state.common.outputs.alb_sg_id,
      ]
      prefix_list_ids = []
      self            = false
      description     = "HTTP"
      protocol        = "tcp"
      from_port       = 80
      to_port         = 80
    },
  ]

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = [
      "0.0.0.0/0",
    ]
  }
}

resource "aws_security_group" "db" {
  name        = "${local.prefix}-db"
  description = "Security group for Aurora Serverless"
  vpc_id      = data.terraform_remote_state.common.outputs.vpc_id
  ingress = [
    {
      cidr_blocks      = []
      ipv6_cidr_blocks = []
      security_groups = [
        aws_security_group.ecs_task.id,
        data.terraform_remote_state.common.outputs.codebuild_sg_id,
      ]
      prefix_list_ids = []
      self            = false
      description     = "MySQL"
      protocol        = "tcp"
      from_port       = 3306
      to_port         = 3306
    },
  ]

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = [
      "0.0.0.0/0",
    ]
  }
}

// IAM
data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type = "Service"
      identifiers = [
        "ecs-tasks.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${replace(title(local.prefix), "-", "")}EcsExecution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_01" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "app" {
  name               = "${replace(title(local.prefix), "-", "")}App"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

resource "aws_iam_role_policy" "app_01" {
  role = aws_iam_role.app.id
  name = "AppPolicy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = ""
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
        ]
        Resource = aws_sqs_queue.messages_queue.arn
      },
    ]
  })
}

// ALB
resource "aws_lb_target_group" "app_tg" {
  name        = "${local.prefix}-app-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.terraform_remote_state.common.outputs.vpc_id
}

resource "aws_lb_listener_rule" "app" {
  listener_arn = data.terraform_remote_state.common.outputs.alb_listener_https_arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }

  condition {
    host_header {
      values = [
        "${terraform.workspace}.${data.terraform_remote_state.common.outputs.domain_name}",
      ]
    }
  }
}

// ECR
resource "aws_ecr_repository" "web" {
  name = "${local.prefix}-web"
}

resource "aws_ecr_repository" "worker" {
  name = "${local.prefix}-worker"
}

resource "aws_ecr_repository" "migrate" {
  name = "${local.prefix}-migrate"
}

// ECS
resource "aws_ecs_cluster" "cluster" {
  name = "${local.prefix}-cluster"
}

resource "aws_ecs_task_definition" "app" {
  family = "${local.prefix}-app"
  requires_compatibilities = [
    "FARGATE",
  ]
  cpu                = "256"
  memory             = "512"
  network_mode       = "awsvpc"
  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.app.arn

  // ダミーのタスク定義
  container_definitions = jsonencode([{
    name  = "nginx"
    image = "nginx:latest"
    portMappings = [
      {
        containerPort = 80
        hostPort      = 80
      }
    ]
  }])
}

resource "aws_ecs_task_definition" "migrate" {
  family = "${local.prefix}-migrate"
  requires_compatibilities = [
    "FARGATE",
  ]
  cpu                = "256"
  memory             = "512"
  network_mode       = "awsvpc"
  execution_role_arn = aws_iam_role.ecs_task_execution.arn

  // ダミーのタスク定義
  container_definitions = jsonencode([{
    name  = "hello-world"
    image = "hello-world:latest"
  }])
}

resource "aws_ecs_service" "app" {
  cluster         = aws_ecs_cluster.cluster.id
  name            = "${local.prefix}-app"
  desired_count   = 1
  task_definition = aws_ecs_task_definition.app.arn
  launch_type     = "FARGATE"

  network_configuration {
    subnets = data.terraform_remote_state.common.outputs.private_subnets
    security_groups = [
      aws_security_group.ecs_task.id,
    ]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app_tg.arn
    container_name   = "nginx"
    container_port   = 80
  }

  lifecycle {
    ignore_changes = [
      desired_count,
      task_definition,
      network_configuration,
      load_balancer,
    ]
  }
}

resource "aws_ecs_service" "migrate" {
  cluster         = aws_ecs_cluster.cluster.id
  name            = "${local.prefix}-migrate"
  desired_count   = 0
  task_definition = aws_ecs_task_definition.migrate.arn
  launch_type     = "FARGATE"

  network_configuration {
    subnets = data.terraform_remote_state.common.outputs.private_subnets
    security_groups = [
      aws_security_group.ecs_task.id,
    ]
    assign_public_ip = false
  }

  lifecycle {
    ignore_changes = [
      desired_count,
      task_definition,
      network_configuration,
    ]
  }
}

// Aurora Serverless
resource "random_password" "root_pass" {
  length           = 16
  special          = true
  override_special = "_%@"
}

resource "random_password" "app_pass" {
  length           = 16
  special          = true
  override_special = "_%@"
}

resource "random_password" "migration_pass" {
  length           = 16
  special          = true
  override_special = "_%@"
}

resource "aws_db_subnet_group" "subnets" {
  name       = "${local.prefix}-subnets"
  subnet_ids = data.terraform_remote_state.common.outputs.private_subnets
}

resource "aws_rds_cluster" "cluster" {
  cluster_identifier   = "${local.prefix}-cluster"
  engine_mode          = "serverless"
  engine               = "aurora-mysql"
  engine_version       = "5.7"
  database_name        = "bbs"
  master_username      = "root"
  master_password      = random_password.root_pass.result
  db_subnet_group_name = aws_db_subnet_group.subnets.name
  skip_final_snapshot  = true
  vpc_security_group_ids = [
    aws_security_group.db.id,
  ]

  scaling_configuration {
    auto_pause               = true
    seconds_until_auto_pause = 300
    max_capacity             = 8
    min_capacity             = 1
    timeout_action           = "ForceApplyCapacityChange"
  }
}

resource "mysql_user" "app" {
  user               = "app"
  host               = "%"
  plaintext_password = random_password.app_pass.result
}

resource "mysql_grant" "app" {
  user     = mysql_user.app.user
  host     = mysql_user.app.host
  database = aws_rds_cluster.cluster.database_name
  privileges = [
    "SELECT",
    "INSERT",
  ]
}

resource "mysql_user" "migration" {
  user               = "migration"
  host               = "%"
  plaintext_password = random_password.migration_pass.result
}

resource "mysql_grant" "migration" {
  user     = mysql_user.migration.user
  host     = mysql_user.migration.host
  database = aws_rds_cluster.cluster.database_name
}

// SQS
resource "aws_sqs_queue" "messages_queue" {
  name                        = "${local.prefix}-message-queue.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
}

// Parameter Store
resource "aws_ssm_parameter" "db_root_pass" {
  name  = "/${terraform.workspace}/db_root_pass"
  type  = "SecureString"
  value = random_password.root_pass.result
}

resource "aws_ssm_parameter" "app_db_user_pass" {
  name  = "/${terraform.workspace}/app_db_user_pass"
  type  = "SecureString"
  value = random_password.app_pass.result
}

resource "aws_ssm_parameter" "migrate_db_user_pass" {
  name  = "/${terraform.workspace}/migrate_db_user_pass"
  type  = "SecureString"
  value = random_password.migration_pass.result
}

resource "aws_cloudwatch_log_group" "ecs_task" {
  name              = "${local.prefix}-ecs-task-logs"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "aurora_error" {
  name              = "/aws/rds/cluster/${aws_rds_cluster.cluster.cluster_identifier}/error"
  retention_in_days = 7
}
