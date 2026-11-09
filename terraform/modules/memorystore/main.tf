variable "name" {
  type    = string
  default = "togglemaster-evaluation-redis"
}

variable "region" {
  type = string
}

variable "network_id" {
  type = string
}

variable "memory_size_gb" {
  type    = number
  default = 1
}

variable "redis_version" {
  type    = string
  default = "REDIS_7_0"
}

variable "private_vpc_connection_id" {
  type = string
}

resource "google_redis_instance" "cache" {
  name           = var.name
  tier           = "BASIC"
  memory_size_gb = var.memory_size_gb
  region         = var.region
  redis_version  = var.redis_version

  authorized_network = var.network_id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  depends_on = [var.private_vpc_connection_id]
}

output "host" {
  value = google_redis_instance.cache.host
}

output "port" {
  value = google_redis_instance.cache.port
}

output "redis_url" {
  value = "redis://${google_redis_instance.cache.host}:${google_redis_instance.cache.port}"
}
