variable "project_id" {
  type = string
}

variable "k8s_namespace" {
  type = string
}

variable "services" {
  description = "Todos os microsservicos — cada um ganha sua propria Google Service Account."
  type        = list(string)
}

variable "sql_services" {
  description = "Servicos que falam com Cloud SQL."
  type        = list(string)
}

variable "database_url_secret_ids" {
  description = "Mapa servico => secret_id da DATABASE_URL no Secret Manager."
  type        = map(string)
}

variable "cluster_id" {
  description = "Forca a criacao do cluster antes dos bindings de Workload Identity."
  type        = string
}

resource "google_service_account" "app" {
  for_each = toset(var.services)

  account_id   = "${each.value}-gsa"
  display_name = "GSA do ${each.value} (ToggleMaster)"
}

resource "google_project_iam_member" "cloudsql_client" {
  for_each = toset(var.sql_services)

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.app[each.value].email}"
}

resource "google_project_iam_member" "pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.app["evaluation-service"].email}"
}

resource "google_project_iam_member" "pubsub_subscriber" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.app["analytics-service"].email}"
}

resource "google_project_iam_member" "firestore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.app["analytics-service"].email}"
}

resource "google_secret_manager_secret_iam_member" "database_url_accessor" {
  for_each = var.database_url_secret_ids

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app[each.key].email}"
}

resource "google_service_account_iam_member" "workload_identity" {
  for_each = toset(var.services)

  service_account_id = google_service_account.app[each.value].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/${each.value}-ksa]"

  depends_on = [var.cluster_id]
}

output "service_account_emails" {
  value = { for k, v in google_service_account.app : k => v.email }
}
