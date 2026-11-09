variable "project_id" {
  description = "ID do projeto GCP onde tudo e provisionado."
  type        = string
}

variable "region" {
  description = "Regiao principal (Cloud SQL, Memorystore, Artifact Registry)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zona do cluster GKE (cluster zonal — mais barato e mais rapido de criar que regional)."
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  type    = string
  default = "togglemaster-gke"
}

variable "k8s_namespace" {
  description = "Namespace onde os 5 microsservicos rodam (usado no binding de Workload Identity)."
  type        = string
  default     = "togglemaster"
}

variable "node_machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "node_min_count" {
  type    = number
  default = 1
}

variable "node_desired_count" {
  type    = number
  default = 2
}

variable "node_max_count" {
  type    = number
  default = 4
}

variable "db_tier" {
  type    = string
  default = "db-f1-micro"
}

variable "redis_memory_size_gb" {
  type    = number
  default = 1
}

variable "firestore_location" {
  type    = string
  default = "us-central1"
}

variable "firestore_collection" {
  description = "Colecao do Firestore que substitui a tabela DynamoDB ToggleMasterAnalytics."
  type        = string
  default     = "ToggleMasterAnalytics"
}

variable "github_repository" {
  description = "Repositorio GitHub no formato owner/repo autorizado a assumir a SA de CI via OIDC."
  type        = string
}

variable "argocd_chart_version" {
  description = "Versao do chart Helm argo-cd (argoproj/argo-helm)."
  type        = string
  default     = "7.7.11"
}
