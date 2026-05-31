output "cloud_run_service_url" {
  description = "Primary Cloud Run service URL"
  value       = google_cloud_run_v2_service.backend.uri
}

output "static_bucket_url" {
  description = "GCS bucket used for static archives"
  value       = google_storage_bucket.static_sites.url
}

output "cloudflare_sachside_records" {
  description = "Cloudflare DNS record IDs for sachside.com"
  value = {
    apex     = { for ip, r in cloudflare_record.sachside_apex : ip => r.hostname }
    www      = cloudflare_record.sachside_www.hostname
    planner  = cloudflare_record.sachside_planner.hostname
    app      = cloudflare_record.sachside_app.hostname
    sachins  = cloudflare_record.sachside_sachins.hostname
  }
}
