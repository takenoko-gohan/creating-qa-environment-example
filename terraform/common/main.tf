terraform {
  backend "s3" {
    key    = "qa_common/terraform.tfstate"
    region = "ap-northeast-1"
  }

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
}

// Route53
// ホストゾーンは別途作成しておいてください
data "aws_route53_zone" "domain" {
  name = var.domain
}

resource "aws_route53_record" "qa_common" {
  zone_id = data.aws_route53_zone.domain.zone_id
  name    = "*.${var.domain}"
  type    = "A"

  alias {
    name                   = aws_lb.qa.dns_name
    zone_id                = aws_lb.qa.zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.domain.zone_id
  ttl             = 60
  allow_overwrite = true
  name            = each.value.name
  records = [
    each.value.record,
  ]
  type = each.value.type
}

// ACM
resource "aws_acm_certificate" "cert" {
  domain_name       = "*.${var.domain}"
  validation_method = "DNS"
  tags = {
    Name = "qa-common"
  }
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn = aws_acm_certificate.cert.arn
  validation_record_fqdns = [
    for record in aws_route53_record.cert_validation : record.fqdn
  ]
}

// VPC
resource "aws_vpc" "qa" {
  cidr_block = var.vpc_cidr
  tags = {
    Name = "qa-vpc"
  }
}

resource "aws_internet_gateway" "qa" {
  vpc_id = aws_vpc.qa.id
  tags = {
    Name = "qa-igw"
  }
}

resource "aws_eip" "qa" {
  count = length(var.subnet_az)
  vpc   = true
}

resource "aws_nat_gateway" "qa" {
  count         = length(var.subnet_az)
  allocation_id = aws_eip.qa[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags = {
    Name = "qa-ngw-${var.subnet_az[count.index]}"
  }
}

resource "aws_subnet" "public" {
  count                   = length(var.subnet_az)
  vpc_id                  = aws_vpc.qa.id
  cidr_block              = cidrsubnet(aws_vpc.qa.cidr_block, 8, count.index)
  availability_zone       = var.subnet_az[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "qa-public-${var.subnet_az[count.index]}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.qa.id
  tags = {
    Name = "qa-public"
  }
}

resource "aws_route" "public" {
  route_table_id         = aws_route_table.public.id
  gateway_id             = aws_internet_gateway.qa.id
  destination_cidr_block = "0.0.0.0/0"
}

resource "aws_route_table_association" "public" {
  count          = length(var.subnet_az)
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public[count.index].id
}

resource "aws_subnet" "private" {
  count                   = length(var.subnet_az)
  vpc_id                  = aws_vpc.qa.id
  cidr_block              = cidrsubnet(aws_vpc.qa.cidr_block, 8, count.index + length(aws_subnet.public))
  availability_zone       = var.subnet_az[count.index]
  map_public_ip_on_launch = false
  tags = {
    Name = "qa-private-${var.subnet_az[count.index]}"
  }
}

resource "aws_route_table" "private" {
  count  = length(var.subnet_az)
  vpc_id = aws_vpc.qa.id
  tags = {
    Name = "qa-private-${var.subnet_az[count.index]}"
  }
}

resource "aws_route" "private" {
  count                  = length(var.subnet_az)
  route_table_id         = aws_route_table.private[count.index].id
  nat_gateway_id         = aws_nat_gateway.qa[count.index].id
  destination_cidr_block = "0.0.0.0/0"
}

resource "aws_route_table_association" "private" {
  count          = length(var.subnet_az)
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.private[count.index].id
}

// Security Group
resource "aws_security_group" "alb" {
  name        = "qa-alb"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.qa.id
  ingress = [
    {
      cidr_blocks = [
        "0.0.0.0/0",
      ]
      ipv6_cidr_blocks = [
        "::/0",
      ]
      security_groups = []
      prefix_list_ids = []
      self            = false
      description     = "HTTP"
      protocol        = "tcp"
      from_port       = 80
      to_port         = 80
    },
    {
      cidr_blocks = [
        "0.0.0.0/0",
      ]
      ipv6_cidr_blocks = [
        "::/0",
      ]
      security_groups = []
      prefix_list_ids = []
      self            = false
      description     = "HTTPS"
      protocol        = "tcp"
      from_port       = 443
      to_port         = 443
    }
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

// ALB
resource "aws_lb" "qa" {
  name                       = "qa-alb"
  internal                   = false
  ip_address_type            = "ipv4"
  load_balancer_type         = "application"
  drop_invalid_header_fields = true
  security_groups = [
    aws_security_group.alb.id,
  ]
  subnets = [
    for subnet in aws_subnet.public : subnet.id
  ]
  tags = {
    Name = "qa-alb"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.qa.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = 443
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.qa.arn
  certificate_arn   = aws_acm_certificate.cert.arn
  port              = 443
  protocol          = "HTTPS"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "403 Forbidden"
      status_code  = 403
    }
  }
}