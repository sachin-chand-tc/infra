resource "google_firestore_index" "qrit_chat_requests_owner_status_created" {
  project    = var.gcp_project_id
  database   = "(default)"
  collection = "qrit_chat_requests"

  fields {
    field_path = "owner_uid"
    order      = "ASCENDING"
  }
  fields {
    field_path = "status"
    order      = "ASCENDING"
  }
  fields {
    field_path = "created_at"
    order      = "DESCENDING"
  }
}

resource "google_firestore_index" "qrit_chat_requests_owner_created" {
  project    = var.gcp_project_id
  database   = "(default)"
  collection = "qrit_chat_requests"

  fields {
    field_path = "owner_uid"
    order      = "ASCENDING"
  }
  fields {
    field_path = "created_at"
    order      = "DESCENDING"
  }
}

resource "google_firestore_index" "qrit_chat_blocks_qr_session" {
  project    = var.gcp_project_id
  database   = "(default)"
  collection = "qrit_chat_blocks"

  fields {
    field_path = "qr_id"
    order      = "ASCENDING"
  }
  fields {
    field_path = "scanner_session_id"
    order      = "ASCENDING"
  }
}

resource "google_firestore_index" "qrit_chat_blocks_qr_ip" {
  project    = var.gcp_project_id
  database   = "(default)"
  collection = "qrit_chat_blocks"

  fields {
    field_path = "qr_id"
    order      = "ASCENDING"
  }
  fields {
    field_path = "scanner_ip_hash"
    order      = "ASCENDING"
  }
}

resource "google_firestore_field" "qrit_chat_ticket_ttl" {
  project    = var.gcp_project_id
  database   = "(default)"
  collection = "qrit_chat_tickets"
  field      = "expires_at"

  ttl_config {}
}

resource "google_firestore_field" "qrit_chat_idempotency_ttl" {
  project    = var.gcp_project_id
  database   = "(default)"
  collection = "qrit_chat_idempotency"
  field      = "expires_at"

  ttl_config {}
}

resource "google_firestore_field" "qrit_chat_rate_window_ttl" {
  project    = var.gcp_project_id
  database   = "(default)"
  collection = "qrit_chat_rate_windows"
  field      = "expires_at"

  ttl_config {}
}
