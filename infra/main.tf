# Main Terraform configuration that orchestrates all modules

module "vpc" {
  source = "./modules/vpc"

  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}

module "ecr" {
  source = "./modules/ecr"

  project_name = var.project_name
  environment  = var.environment
}

module "alb" {
  source = "./modules/alb"

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  health_check_path  = var.health_check_path
  container_port     = var.container_port
}

module "ecs" {
  source = "./modules/ecs"

  project_name        = var.project_name
  environment         = var.environment
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  public_subnet_ids   = module.vpc.public_subnet_ids
  alb_target_group_arn = module.alb.target_group_arn
  alb_security_group_id = module.alb.alb_security_group_id
  container_image     = var.container_image != "" ? var.container_image : "${module.ecr.repository_url}:latest"
  container_port      = var.container_port
  container_cpu       = var.container_cpu
  container_memory    = var.container_memory
  desired_count       = var.desired_count
  rails_env           = var.rails_env
  rails_log_level     = var.rails_log_level
}
