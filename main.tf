
terraform {
  required_version = ">= 0.14"
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

  gitlab    = var.gitlab
  autoscale = var.autoscale
  cache     = module.cache.bucket
}
