terraform {
  backend "gcs" {
    bucket = "fiap-4-514223-tfstate"
    prefix = "fase4/togglemaster"
  }
}
