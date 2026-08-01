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

resource "google_storage_bucket" "qrit_chat_archives" {
  name                        = var.qrit_chat_archive_bucket_name
  project                     = var.gcp_project_id
  location                    = var.static_bucket_location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 2
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket_iam_member" "qrit_chat_archive_writer" {
  bucket = google_storage_bucket.qrit_chat_archives.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.cloud_run_service_account}"
}
