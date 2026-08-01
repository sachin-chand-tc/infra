resource "google_cloud_run_v2_job" "qrit_chat_archive" {
  provider = google-beta
  name     = var.qrit_chat_archive_job
  location = var.region
  project  = var.gcp_project_id

  template {
    template {
      service_account = var.cloud_run_service_account
      timeout         = "900s"
      max_retries     = 3

      containers {
        image   = var.cloud_run_container_image
        command = ["/qrit-chat-archive"]

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        env {
          name  = "FIREBASE_PROJECT_ID"
          value = var.gcp_project_id
        }
        env {
          name  = "QRIT_CHAT_ARCHIVE_BUCKET"
          value = google_storage_bucket.qrit_chat_archives.name
        }
        env {
          name = "QRIT_CHAT_TOKEN_SECRET"
          value_source {
            secret_key_ref {
              secret  = var.cloud_run_secret_env_vars["QRIT_CHAT_TOKEN_SECRET"]
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [client, client_version, template[0].template[0].containers[0].image]
  }

  depends_on = [
    google_project_service.required,
    google_project_iam_member.cloud_run_secret_accessor,
    google_storage_bucket_iam_member.qrit_chat_archive_writer,
  ]
}

resource "google_service_account" "qrit_chat_scheduler" {
  project      = var.gcp_project_id
  account_id   = "qrit-chat-scheduler"
  display_name = "QRIT chat archive scheduler"
}

resource "google_cloud_run_v2_job_iam_member" "qrit_chat_scheduler_invoker" {
  project  = var.gcp_project_id
  location = var.region
  name     = google_cloud_run_v2_job.qrit_chat_archive.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.qrit_chat_scheduler.email}"
}

resource "google_cloud_scheduler_job" "qrit_chat_archive" {
  project          = var.gcp_project_id
  region           = var.region
  name             = "qrit-chat-archive-hourly"
  description      = "Packs closed QRIT encrypted chat messages into bounded CBOR archives"
  schedule         = "15 * * * *"
  time_zone        = "Etc/UTC"
  attempt_deadline = "320s"

  retry_config {
    retry_count          = 3
    min_backoff_duration = "30s"
    max_backoff_duration = "300s"
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.gcp_project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.qrit_chat_archive.name}:run"

    oauth_token {
      service_account_email = google_service_account.qrit_chat_scheduler.email
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.qrit_chat_scheduler_invoker]
}
