variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
  default     = "starkindustries-og"
}

variable "region" {
  description = "GCP region where Cloud Run is deployed"
  type        = string
  default     = "asia-northeast1"
}

variable "cloud_run_service" {
  description = "Name of the Cloud Run service all domains point to"
  type        = string
  default     = "feedseeker-website"
}

variable "cloud_run_container_image" {
  description = "Current container image for the Cloud Run service. Deployments may update this outside OpenTofu."
  type        = string
  default     = "gcr.io/starkindustries-og/feedseeker-website:76cccc3-20260505053944"
}

variable "cloud_run_service_account" {
  description = "Service account used by Cloud Run revisions"
  type        = string
  default     = "75318549550-compute@developer.gserviceaccount.com"
}

variable "cloud_run_env_vars" {
  description = "Environment variables configured on the Cloud Run service"
  type        = map(string)
  default = {
    HTTP_PORT        = "8080"
    GRPC_PORT        = "9090"
    ENVIRONMENT      = "production"
    GCS_STATIC_BUCKET = "starkindustries-og-static-an1"
  }
}

variable "static_bucket_name" {
  description = "Primary GCS bucket that stores static frontend archives"
  type        = string
  default     = "starkindustries-og-static-an1"
}

variable "static_bucket_location" {
  description = "Region for the static frontend bucket"
  type        = string
  default     = "ASIA-NORTHEAST1"
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token. Set via env: TF_VAR_cloudflare_api_token=..."
  type        = string
  sensitive   = true
}
