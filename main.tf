locals {
  vpc_name     = coalesce(var.name, "${var.environment}-eks-vpc")
  cluster_name = coalesce(var.cluster_name, "${var.environment}-eks")
  environment_tags = merge(var.tags, {
    Environment = var.environment
  })
}

module "vpc" {
  source = "./modules/vpc"

  name               = local.vpc_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  tags               = local.environment_tags
}

module "eks" {
  source = "./modules/eks"

  cluster_name        = local.cluster_name
  kubernetes_version  = var.kubernetes_version
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = values(module.vpc.private_subnet_ids)
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  tags                = local.environment_tags

  depends_on = [module.vpc]
}
