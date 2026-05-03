#!/bin/bash
# =============================================================
# deploy-backend.sh — Build & deploy the Go server to Cloud Run
# =============================================================
# Lives in: infra/
# App source: ../insta-scraper-backend/  (sibling repo)
# Dockerfile:  infra/Dockerfile           (this repo)
#
# Usage:
#   ./deploy-backend.sh                     # uses GCP_PROJECT_ID env var
#   GCP_PROJECT_ID=my-project ./deploy-backend.sh
# =============================================================

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# ── Resolve paths ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/../insta-scraper-backend" && pwd)"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"

# ── Configuration ──────────────────────────────────────────────
PROJECT_ID="${GCP_PROJECT_ID:-}"
SERVICE_NAME="feedseeker-website"
REGION="asia-northeast1"

if [[ -z "$PROJECT_ID" ]]; then
  echo -e "${BLUE}Enter your Google Cloud Project ID:${NC}"
  read -r PROJECT_ID
fi

IMAGE_NAME="gcr.io/${PROJECT_ID}/${SERVICE_NAME}"

echo -e "${BLUE}══════════════════════════════════════════════${NC}"
echo -e "${BLUE}  deploy-backend — feedseeker-website${NC}"
echo -e "${BLUE}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}App source:  $APP_ROOT${NC}"
echo -e "${GREEN}Dockerfile:  $DOCKERFILE${NC}"
echo -e "${GREEN}Image:       $IMAGE_NAME${NC}"
echo -e "${GREEN}Region:      $REGION${NC}"
echo ""

# ── Pre-flight checks ──────────────────────────────────────────
if ! command -v gcloud &> /dev/null; then
  echo -e "${RED}Error: gcloud CLI not installed${NC}"
  exit 1
fi
if ! command -v docker &> /dev/null; then
  echo -e "${RED}Error: Docker not installed${NC}"
  exit 1
fi

# ── Build Docker image ─────────────────────────────────────────
echo -e "${BLUE}Building Docker image...${NC}"
gcloud auth configure-docker --quiet
docker build \
  --platform linux/amd64 \
  -f "$DOCKERFILE" \
  -t "${IMAGE_NAME}:latest" \
  "$APP_ROOT"

# ── Push to GCR ───────────────────────────────────────────────
echo -e "${BLUE}Pushing to GCR...${NC}"
docker push "${IMAGE_NAME}:latest"

# ── Deploy to Cloud Run ───────────────────────────────────────
echo -e "${BLUE}Deploying to Cloud Run...${NC}"
gcloud run deploy "${SERVICE_NAME}" \
  --image="${IMAGE_NAME}:latest" \
  --platform=managed \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --allow-unauthenticated \
  --memory=512Mi \
  --cpu=1 \
  --min-instances=0 \
  --max-instances=10 \
  --port=8080 \
  --set-env-vars="HTTP_PORT=8080,GRPC_PORT=9090,ENVIRONMENT=production,GCS_STATIC_BUCKET=starkindustries-og-static-an1"

# ── Print service URL ─────────────────────────────────────────
SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" \
  --platform=managed \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format='value(status.url)')

echo ""
echo -e "${GREEN}✓ Deployment successful!${NC}"
echo -e "${GREEN}  Service URL: ${SERVICE_URL}${NC}"
