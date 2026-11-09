output "network_id" {
  value = google_compute_network.vpc.id
}

output "network_name" {
  value = google_compute_network.vpc.name
}

output "subnet_id" {
  value = google_compute_subnetwork.subnet.id
}

output "pods_range_name" {
  value = "pods"
}

output "services_range_name" {
  value = "services"
}

output "private_vpc_connection_id" {
  value = google_service_networking_connection.private_vpc_connection.id
}
