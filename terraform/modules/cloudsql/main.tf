locals {
  services = keys(var.instances)
}

resource "random_password" "db" {
  for_each = var.instances

  length  = 24
  special = false
}

resource "google_sql_database_instance" "postgres" {
  for_each = var.instances

  name             = "togglemaster-${each.key}-db"
  database_version = var.database_version
  region           = var.region

  settings {
    tier              = var.tier
    availability_type = "ZONAL"
    disk_size         = 10
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
    }

    backup_configuration {
      enabled = false
    }

    insights_config {
      query_insights_enabled = true
    }
  }

  deletion_protection = false

  depends_on = [var.private_vpc_connection_id]
}

resource "google_sql_database" "database" {
  for_each = var.instances

  name     = each.value.db_name
  instance = google_sql_database_instance.postgres[each.key].name
}

resource "google_sql_user" "user" {
  for_each = var.instances

  name     = each.value.user_name
  instance = google_sql_database_instance.postgres[each.key].name
  password = random_password.db[each.key].result
}

resource "google_secret_manager_secret" "database_url" {
  for_each = var.instances

  secret_id = "${each.key}-database-url"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "database_url" {
  for_each = var.instances

  secret = google_secret_manager_secret.database_url[each.key].id
  secret_data = format(
    "postgres://%s:%s@%s:5432/%s?sslmode=disable",
    each.value.user_name,
    random_password.db[each.key].result,
    google_sql_database_instance.postgres[each.key].private_ip_address,
    each.value.db_name,
  )
}
