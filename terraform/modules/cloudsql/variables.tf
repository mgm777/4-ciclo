variable "region" {
  type = string
}

variable "network_id" {
  type = string
}

variable "private_vpc_connection_id" {
  description = "Forca a criacao do peering antes das instancias (depends_on)."
  type        = string
}

variable "tier" {
  type    = string
  default = "db-f1-micro"
}

variable "database_version" {
  type    = string
  default = "POSTGRES_15"
}

variable "instances" {
  description = "Mapa servico => { db_name, user_name }. Uma instancia Cloud SQL por servico (database-per-service)."
  type = map(object({
    db_name   = string
    user_name = string
  }))
}
