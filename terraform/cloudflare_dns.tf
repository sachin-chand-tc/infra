# ── Cloudflare DNS Records ─────────────────────────────────────────────────────
# Google Cloud Run domain mappings require specific DNS records.
# Apex domains (@) need A records; subdomains use CNAME → ghs.googlehosted.com.
#
# All records are proxied (Cloudflare orange-cloud) so Cloudflare handles TLS
# termination and DDoS protection at the edge.

# ── Zone lookups (Cloudflare knows zones by domain name) ─────────────────────
data "cloudflare_zone" "sachside" {
  name = "sachside.com"
}

data "cloudflare_zone" "apnijodi" {
  name = "apnijodi.com"
}

data "cloudflare_zone" "feedseeker" {
  name = "feedseeker.com"
}

# ── Google Cloud Run IPs for apex A records ───────────────────────────────────
# These are the stable IP addresses GCP uses for Cloud Run custom domain mappings.
locals {
  cloud_run_ips = [
    "216.239.32.21",
    "216.239.34.21",
    "216.239.36.21",
    "216.239.38.21",
  ]
}

# ── sachside.com ──────────────────────────────────────────────────────────────

resource "cloudflare_record" "sachside_apex" {
  for_each = toset(local.cloud_run_ips)

  zone_id = data.cloudflare_zone.sachside.id
  name    = "@"
  type    = "A"
  content = each.value
  proxied = true

  # Disambiguate multiple A records with the IP in the comment
  comment = "Cloud Run — ${each.value}"
}

resource "cloudflare_record" "sachside_www" {
  zone_id = data.cloudflare_zone.sachside.id
  name    = "www"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = true
}

resource "cloudflare_record" "sachside_planner" {
  zone_id = data.cloudflare_zone.sachside.id
  name    = "planner"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  allow_overwrite = true
  proxied = false
}

resource "cloudflare_record" "sachside_app" {
  zone_id = data.cloudflare_zone.sachside.id
  name    = "app"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = false
}

resource "cloudflare_record" "sachside_sachins" {
  zone_id = data.cloudflare_zone.sachside.id
  name    = "sachins"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = false
}

resource "cloudflare_record" "sachside_fifa" {
  zone_id = data.cloudflare_zone.sachside.id
  name    = "fifa"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = false
}

resource "cloudflare_record" "sachside_fifa_www" {
  zone_id = data.cloudflare_zone.sachside.id
  name    = "www.fifa"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = false
}

resource "cloudflare_record" "sachside_qr" {
  zone_id = data.cloudflare_zone.sachside.id
  name    = "qr"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = false
}

resource "cloudflare_record" "sachside_qr_www" {
  zone_id = data.cloudflare_zone.sachside.id
  name    = "www.qr"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = false
}

# ── apnijodi.com ──────────────────────────────────────────────────────────────

resource "cloudflare_record" "apnijodi_apex" {
  for_each = toset(local.cloud_run_ips)

  zone_id = data.cloudflare_zone.apnijodi.id
  name    = "@"
  type    = "A"
  content = each.value
  proxied = true

  comment = "Cloud Run — ${each.value}"
}

resource "cloudflare_record" "apnijodi_www" {
  zone_id = data.cloudflare_zone.apnijodi.id
  name    = "www"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = true
}

# ── feedseeker.com ────────────────────────────────────────────────────────────

resource "cloudflare_record" "feedseeker_apex" {
  for_each = toset(local.cloud_run_ips)

  zone_id = data.cloudflare_zone.feedseeker.id
  name    = "@"
  type    = "A"
  content = each.value
  proxied = true

  comment = "Cloud Run — ${each.value}"
}

resource "cloudflare_record" "feedseeker_www" {
  zone_id = data.cloudflare_zone.feedseeker.id
  name    = "www"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = true
}
