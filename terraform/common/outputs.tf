output "vpc_id" {
  value = aws_vpc.qa.id
}
output "alb_sg_id" {
  value = aws_security_group.alb.id
}
output "private_subnets" {
  value = aws_subnet.private.*.id
}
output "domain_name" {
  value = data.aws_route53_zone.domain.name
}
output "alb_listener_https_arn" {
  value = aws_lb_listener.https.arn
}