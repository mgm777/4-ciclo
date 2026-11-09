locals {
  services = [
    "auth-service",
    "flag-service",
    "targeting-service",
    "evaluation-service",
    "analytics-service",
  ]

  sql_instances = {
    "auth-service"      = { db_name = "auth_db", user_name = "auth_user" }
    "flag-service"      = { db_name = "flags_db", user_name = "flags_user" }
    "targeting-service" = { db_name = "targeting_db", user_name = "targeting_user" }
  }

  required_apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "sqladmin.googleapis.com",
    "redis.googleapis.com",
    "pubsub.googleapis.com",
    "firestore.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "servicenetworking.googleapis.com",
  ]
}

module "project_services" {
  source = "./modules/project-services"

  project_id = var.project_id
  apis       = local.required_apis
}

module "networking" {
  source = "./modules/networking"

  name_prefix = var.cluster_name
  region      = var.region

  depends_on = [module.project_services]
}

module "gke" {
  source = "./modules/gke"

  project_id          = var.project_id
  cluster_name        = var.cluster_name
  zone                = var.zone
  network_id          = module.networking.network_id
  subnet_id           = module.networking.subnet_id
  pods_range_name     = module.networking.pods_range_name
  services_range_name = module.networking.services_range_name
  node_machine_type   = var.node_machine_type
  node_desired_count  = var.node_desired_count
  node_min_count      = var.node_min_count
  node_max_count      = var.node_max_count

  depends_on = [module.project_services]
}

module "cloudsql" {
  source = "./modules/cloudsql"

  region                    = var.region
  network_id                = module.networking.network_id
  private_vpc_connection_id = module.networking.private_vpc_connection_id
  tier                      = var.db_tier
  instances                 = local.sql_instances

  depends_on = [module.project_services]
}

module "memorystore" {
  source = "./modules/memorystore"

  region                    = var.region
  network_id                = module.networking.network_id
  private_vpc_connection_id = module.networking.private_vpc_connection_id
  memory_size_gb            = var.redis_memory_size_gb

  depends_on = [module.project_services]
}

module "messaging" {
  source = "./modules/messaging"

  depends_on = [module.project_services]
}

module "firestore" {
  source = "./modules/firestore"

  project_id  = var.project_id
  location_id = var.firestore_location

  depends_on = [module.project_services]
}

module "artifact_registry" {
  source = "./modules/artifact-registry"

  project_id = var.project_id
  region     = var.region
  services   = local.services

  depends_on = [module.project_services]
}

module "iam" {
  source = "./modules/iam"

  project_id              = var.project_id
  k8s_namespace           = var.k8s_namespace
  services                = local.services
  sql_services            = keys(local.sql_instances)
  database_url_secret_ids = module.cloudsql.database_url_secret_ids
  cluster_id              = module.gke.cluster_name
}

module "cicd" {
  source = "./modules/cicd"

  project_id        = var.project_id
  github_repository = var.github_repository

  depends_on = [module.project_services]
}
