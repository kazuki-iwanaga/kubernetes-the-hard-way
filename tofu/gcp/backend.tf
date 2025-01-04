terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "6.14.1"
    }
  }

  backend "gcs" {
    bucket = var.tfstate_bucket
  }
}