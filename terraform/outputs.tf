output "gke_cluster_name" {
  value = module.gke.cluster_name
}

output "kubectl_config_command" {
  description = "Comando para apontar o kubectl para o cluster recem-criado."
  value       = "gcloud container clusters get-credentials ${module.gke.cluster_name} --zone ${var.zone} --project ${var.project_id}"
}

output "artifact_registry_repos" {
  value = module.artifact_registry.repository_urls
}

output "cloudsql_private_ips" {
  value = module.cloudsql.private_ips
}

output "cloudsql_instance_names" {
  value = module.cloudsql.instance_names
}

output "database_url_secret_ids" {
  value = module.cloudsql.database_url_secret_ids
}

output "redis_url" {
  value = module.memorystore.redis_url
}

output "pubsub_topic" {
  value = module.messaging.topic_name
}

output "pubsub_subscription" {
  value = module.messaging.subscription_name
}

output "firestore_database" {
  value = module.firestore.database_name
}

output "service_account_emails" {
  value = module.iam.service_account_emails
}

output "github_secret_GCP_WIF_PROVIDER" {
  description = "Settings > Secrets and variables > Actions > GCP_WIF_PROVIDER"
  value       = module.cicd.workload_identity_provider
}

output "github_secret_GCP_CI_SERVICE_ACCOUNT" {
  description = "Settings > Secrets and variables > Actions > GCP_CI_SERVICE_ACCOUNT"
  value       = module.cicd.service_account_email
}
