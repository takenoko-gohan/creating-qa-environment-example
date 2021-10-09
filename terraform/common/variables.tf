variable "domain" {
  type        = string
  description = "QA 環境で使用するドメインをしてします"
}
variable "vpc_cidr" {
  type        = string
  description = "QA 環境 VPC の IPv4 アドレス範囲を指定します"
  default     = "172.16.0.0/16"
}
variable "subnet_az" {
  type        = list(string)
  description = "サブネットの AZ を指定します"
  default = [
    "ap-northeast-1a",
    "ap-northeast-1c",
  ]
}