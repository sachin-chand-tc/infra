locals {
  required_gcp_services = toset([
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "containerregistry.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
  ])
}

resource "google_project_service" "required" {
  for_each = local.required_gcp_services

  project            = var.gcp_project_id
  service            = each.value
  disable_on_destroy = false
}