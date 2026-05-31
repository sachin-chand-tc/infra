resource "google_storage_bucket" "static_sites" {
  name                        = var.static_bucket_name
  project                     = var.gcp_project_id
  location                    = var.static_bucket_location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "inherited"
  force_destroy               = false

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  depends_on = [google_project_service.required]
}