
terraform {
  required_version = ">= 0.12"
}

module "cache" {
  source = "./modules/cache"

  count = var.cache == null ? 1 : 0

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
  cache     = var.cache == null ? module.cache[0].bucket : var.cache
}
