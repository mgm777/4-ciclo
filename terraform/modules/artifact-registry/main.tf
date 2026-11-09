variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "services" {
  description = "Um repositorio Docker por microsservico (equivalente aos 5 repositorios ECR)."
  type        = list(string)
}

resource "google_artifact_registry_repository" "service_repos" {
  for_each = toset(var.services)

  location      = var.region
  repository_id = each.value
  format        = "DOCKER"
  description   = "Imagens Docker do ${each.value} (ToggleMaster)"

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
}

output "repository_urls" {
  value = {
    for k, v in google_artifact_registry_repository.service_repos :
    k => "${var.region}-docker.pkg.dev/${var.project_id}/${v.repository_id}"
  }
}
