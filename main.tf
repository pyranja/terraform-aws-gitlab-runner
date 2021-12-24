
terraform {
  required_version = ">= 0.14"
}

resource "aws_secretsmanager_secret" "token" {
  name        = "${var.name}/registration_token"
  description = "Gitlab registration token for runner ${var.name}."
  tags        = var.tags

  recovery_window_in_days = 0
}

module "cache" {
  source = "./modules/cache"

  name = var.name
  tags = var.tags
}

module "controller" {
  source = "./modules/controller"

  name = var.name
  tags = var.tags

  subnet_id = var.subnet_id

  gitlab       = var.gitlab
  gitlab_token = aws_secretsmanager_secret.token
  autoscale    = var.autoscale
  cache        = module.cache.bucket
}
