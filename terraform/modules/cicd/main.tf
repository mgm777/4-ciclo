variable "project_id" {
  type = string
}

variable "github_repository" {
  description = "owner/repo autorizado a assumir a SA de CI."
  type        = string
}

variable "pool_id" {
  type    = string
  default = "github-actions-pool"
}

variable "provider_id" {
  type    = string
  default = "github-provider"
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = var.pool_id
  display_name              = "GitHub Actions"
  description               = "Pool OIDC para os pipelines de CI do ToggleMaster"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.actor"      = "assertion.actor"
  }

  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "ci" {
  account_id   = "github-actions-ci"
  display_name = "GitHub Actions CI (ToggleMaster)"
}

resource "google_project_iam_member" "ci_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

resource "google_service_account_iam_member" "ci_workload_identity" {
  service_account_id = google_service_account.ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

output "workload_identity_provider" {
  description = "Valor do secret GCP_WIF_PROVIDER no GitHub."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "service_account_email" {
  description = "Valor do secret GCP_CI_SERVICE_ACCOUNT no GitHub."
  value       = google_service_account.ci.email
}
