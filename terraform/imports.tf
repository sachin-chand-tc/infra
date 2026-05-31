# ── Import existing resources into OpenTofu state ─────────────────────────────
# These blocks tell OpenTofu that the resources already exist in GCP/Cloudflare
# so it adopts them instead of trying to recreate them.
#
# Run once: tofu plan  (will show no-op for imported resources if config matches)
#
# Cloud Run domain mapping import ID format:
#   projects/{project}/locations/{region}/domainMappings/{domain}

# Import ID format: {location}/{project}/{name}
import {
  id = "projects/starkindustries-og/locations/asia-northeast1/services/feedseeker-website"
  to = google_cloud_run_v2_service.backend
}

import {
  id = "starkindustries-og/starkindustries-og-static-an1"
  to = google_storage_bucket.static_sites
}

# ── Cloudflare DNS imports ────────────────────────────────────────────────────
# Cloudflare record IDs are not human-readable. Run this to get them:
#
#   curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
#     "https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records" \
#     | jq '.result[] | {id, name, type, content}'
#
# Then add import blocks like:
#
# import {
#   to = cloudflare_record.sachside_planner
#   id = "{zone_id}/{record_id}"
# }
#
# If the records don't exist yet in Cloudflare (e.g. planner.sachside.com),
# tofu apply will create them — no import needed.

# ── Intentionally unmanaged GCP resources ─────────────────────────────────────
# gs://starkindustries-og_cloudbuild is auto-created and owned by Cloud Build.
# We do not manage it here to avoid fighting Google's lifecycle.
# Cloud Run domain mappings are intentionally managed by gcloud for now.
# The Google provider is returning read/import errors for existing mappings in this
# project, so custom domains remain outside OpenTofu until that provider path is reliable.
