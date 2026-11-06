#!/bin/bash
# =============================================================
# setup-backend-ci.sh — one-time setup so insta-scraper-backend deploys itself
# =============================================================
# Run this yourself, once, from a machine where gcloud is signed in as a
# project owner and gh is signed in to GitHub:
#
#   bash scripts/setup-backend-ci.sh
#
# It:
#   1. grants the github-actions service account Cloud Build Editor (it
#      already has Cloud Run Admin, Storage Admin and Service Account User),
#   2. creates a new key for it,
#   3. stores the key as the GCP_SA_KEY Actions secret of
#      sachin-chand-tc/insta-scraper-backend,
#   4. deletes the local key file.
#
# Older keys on the account are listed at the end so you can delete unused ones.
# =============================================================
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-starkindustries-og}"
SA="${CI_SERVICE_ACCOUNT:-github-actions@${PROJECT_ID}.iam.gserviceaccount.com}"
REPO="${BACKEND_REPO:-sachin-chand-tc/insta-scraper-backend}"

command -v gcloud >/dev/null || { echo "gcloud is required"; exit 1; }
command -v gh >/dev/null || { echo "gh is required"; exit 1; }

echo "Project:         $PROJECT_ID"
echo "Service account: $SA"
echo "GitHub repo:     $REPO"
read -r -p "Continue? [y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "Aborted."; exit 1; }

echo "1/3 Granting roles/cloudbuild.builds.editor..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA}" \
  --role="roles/cloudbuild.builds.editor" \
  --condition=None >/dev/null

KEY_DIR="$(mktemp -d)"
trap 'rm -rf "$KEY_DIR"' EXIT
echo "2/3 Creating a key..."
gcloud iam service-accounts keys create "$KEY_DIR/key.json" --iam-account="$SA" --project="$PROJECT_ID"

echo "3/3 Saving it as GCP_SA_KEY in $REPO..."
gh secret set GCP_SA_KEY --repo "$REPO" < "$KEY_DIR/key.json"

echo
echo "Done. The key file was deleted. Keys on $SA now:"
gcloud iam service-accounts keys list --iam-account="$SA" --project="$PROJECT_ID" --managed-by=user
echo "Delete any you don't use with: gcloud iam service-accounts keys delete <KEY_ID> --iam-account=$SA"
