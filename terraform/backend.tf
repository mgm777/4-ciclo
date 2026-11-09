terraform {
  backend "gcs" {
    bucket = "fiap-3-508723-tfstate"
    prefix = "fase3/togglemaster"
  }
}
