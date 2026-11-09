output "connection_names" {
  value = { for k, v in google_sql_database_instance.postgres : k => v.connection_name }
}

output "private_ips" {
  value = { for k, v in google_sql_database_instance.postgres : k => v.private_ip_address }
}

output "instance_names" {
  value = { for k, v in google_sql_database_instance.postgres : k => v.name }
}

output "database_url_secret_ids" {
  description = "IDs dos secrets no Secret Manager com a DATABASE_URL de cada servico."
  value       = { for k, v in google_secret_manager_secret.database_url : k => v.secret_id }
}
