variable "project_id" {
  type = string
}

variable "location_id" {
  type = string
}

variable "database_name" {
  type    = string
  default = "(default)"
}

resource "google_firestore_database" "analytics" {
  project     = var.project_id
  name        = var.database_name
  location_id = var.location_id
  type        = "FIRESTORE_NATIVE"

  deletion_policy = "DELETE"
}

output "database_name" {
  value = google_firestore_database.analytics.name
}
