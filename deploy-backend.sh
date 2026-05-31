#!/bin/bash
# =============================================================
# deploy-backend.sh — Build & deploy the Go server to Cloud Run
# =============================================================
# Lives in: infra/
# App source: ../insta-scraper-backend/  (sibling repo by default)
# Dockerfile:  infra/Dockerfile           (staged into build context)
#
# Best-practice path:
#   - stages a clean build context locally
#   - uses Cloud Build (no local Docker daemon required)
#   - deploys an immutable image tag to Cloud Run
#
# Usage:
#   ./deploy-backend.sh
#   GCP_PROJECT_ID=my-project ./deploy-backend.sh
#   APP_ROOT=/path/to/app IMAGE_TAG=$(git rev-parse --short HEAD) ./deploy-backend.sh
# =============================================================

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# ── Resolve paths ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_APP_ROOT="$SCRIPT_DIR/../insta-scraper-backend"
APP_ROOT="${APP_ROOT:-$DEFAULT_APP_ROOT}"
APP_ROOT="$(cd "$APP_ROOT" && pwd)"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"

# ── Configuration ──────────────────────────────────────────────
PROJECT_ID="${GCP_PROJECT_ID:-}"
SERVICE_NAME="${CLOUD_RUN_SERVICE:-feedseeker-website}"
REGION="${REGION:-asia-northeast1}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-gcr.io}"
IMAGE_REPO="${IMAGE_REPO:-$SERVICE_NAME}"
IMAGE_TAG="${IMAGE_TAG:-}"
ENV_VARS="${DEPLOY_ENV_VARS:-HTTP_PORT=8080,GRPC_PORT=9090,ENVIRONMENT=production,GCS_STATIC_BUCKET=starkindustries-og-static-an1}"
KEEP_IMAGE_DIGESTS="${KEEP_IMAGE_DIGESTS:-2}"
KEEP_BUILD_RECORDS="${KEEP_BUILD_RECORDS:-2}"
CLEANUP_OLD_IMAGES="${CLEANUP_OLD_IMAGES:-true}"
CLEANUP_OLD_BUILDS="${CLEANUP_OLD_BUILDS:-true}"
QUIET_FLAG=""

if [[ "${QUIET:-false}" == "true" ]]; then
	QUIET_FLAG="--quiet"
fi

cleanup_old_gcr_images() {
  if [[ "$CLEANUP_OLD_IMAGES" != "true" ]]; then
    return
  fi
  if ! command -v mapfile >/dev/null 2>&1; then
    echo -e "${BLUE}Skipping image cleanup: shell does not support mapfile (use bash >= 4).${NC}"
    return
  fi
  if [[ "$IMAGE_REGISTRY" != "gcr.io" ]]; then
    echo -e "${BLUE}Skipping image cleanup for non-GCR registry ${IMAGE_REGISTRY}.${NC}"
    return
  fi

  echo -e "${BLUE}Cleaning up old image digests (keeping ${KEEP_IMAGE_DIGESTS})...${NC}"
  mapfile -t digests < <(gcloud container images list-tags "$IMAGE_NAME" \
    --project "$PROJECT_ID" \
    --sort-by='~TIMESTAMP' \
    --format='get(digest)' | awk 'NF {print $0}' | awk '!seen[$0]++')

  if (( ${#digests[@]} <= KEEP_IMAGE_DIGESTS )); then
    echo -e "${GREEN}  No old image digests to delete${NC}"
    return
  fi

  local keep_index=0
  for digest in "${digests[@]}"; do
    keep_index=$((keep_index + 1))
    if (( keep_index <= KEEP_IMAGE_DIGESTS )); then
      continue
    fi
    if [[ -z "$digest" ]]; then
      continue
    fi
    gcloud container images delete "${IMAGE_NAME}@${digest}" \
      --project "$PROJECT_ID" \
      --force-delete-tags \
      --quiet >/dev/null
    echo -e "${GREEN}  Deleted digest ${digest}${NC}"
  done
}

cleanup_old_build_records() {
  if [[ "$CLEANUP_OLD_BUILDS" != "true" ]]; then
    return
  fi
  if ! command -v mapfile >/dev/null 2>&1; then
    echo -e "${BLUE}Skipping build cleanup: shell does not support mapfile (use bash >= 4).${NC}"
    return
  fi

  echo -e "${BLUE}Cleaning up old Cloud Build records (keeping ${KEEP_BUILD_RECORDS})...${NC}"
  mapfile -t build_ids < <(gcloud builds list \
    --project "$PROJECT_ID" \
    --sort-by='~createTime' \
    --format='value(id)')

  if (( ${#build_ids[@]} <= KEEP_BUILD_RECORDS )); then
    echo -e "${GREEN}  No old build records to delete${NC}"
    return
  fi

  local keep_index=0
  for build_id in "${build_ids[@]}"; do
    keep_index=$((keep_index + 1))
    if (( keep_index <= KEEP_BUILD_RECORDS )); then
      continue
    fi
    if [[ -z "$build_id" ]]; then
      continue
    fi
    gcloud builds delete "$build_id" --project "$PROJECT_ID" --quiet >/dev/null
    echo -e "${GREEN}  Deleted build record ${build_id}${NC}"
  done
}

if [[ -z "$PROJECT_ID" ]]; then
  echo -e "${BLUE}Enter your Google Cloud Project ID:${NC}"
  read -r PROJECT_ID
fi

if [[ -z "$IMAGE_TAG" ]]; then
	if command -v git &> /dev/null && git -C "$APP_ROOT" rev-parse --is-inside-work-tree &> /dev/null; then
		IMAGE_TAG="$(git -C "$APP_ROOT" rev-parse --short HEAD)-$(date +%Y%m%d%H%M%S)"
	else
		IMAGE_TAG="$(date +%Y%m%d%H%M%S)"
	fi
fi

IMAGE_NAME="${IMAGE_REGISTRY}/${PROJECT_ID}/${IMAGE_REPO}"
IMAGE_REF="${IMAGE_NAME}:${IMAGE_TAG}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/feedseeker-build.XXXXXX")"

cleanup() {
	rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

echo -e "${BLUE}══════════════════════════════════════════════${NC}"
echo -e "${BLUE}  deploy-backend — feedseeker-website${NC}"
echo -e "${BLUE}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}App source:  $APP_ROOT${NC}"
echo -e "${GREEN}Dockerfile:  $DOCKERFILE${NC}"
echo -e "${GREEN}Image:       $IMAGE_REF${NC}"
echo -e "${GREEN}Region:      $REGION${NC}"
echo ""

# ── Pre-flight checks ──────────────────────────────────────────
if ! command -v gcloud &> /dev/null; then
  echo -e "${RED}Error: gcloud CLI not installed${NC}"
  exit 1
fi
if [[ ! -f "$DOCKERFILE" ]]; then
  echo -e "${RED}Error: Dockerfile not found at $DOCKERFILE${NC}"
  exit 1
fi
if [[ ! -d "$APP_ROOT" ]]; then
  echo -e "${RED}Error: app root not found at $APP_ROOT${NC}"
  exit 1
fi

# ── Stage clean build context ─────────────────────────────────
echo -e "${BLUE}Staging build context...${NC}"
rsync -a "$APP_ROOT/" "$STAGING_DIR/"
cp "$DOCKERFILE" "$STAGING_DIR/Dockerfile"
rm -f "$STAGING_DIR/.gcloudignore"
if [[ -f "$SCRIPT_DIR/.dockerignore" ]]; then
	cp "$SCRIPT_DIR/.dockerignore" "$STAGING_DIR/.dockerignore"
fi

# ── Build image in Cloud Build ────────────────────────────────
echo -e "${BLUE}Building image in Cloud Build...${NC}"
gcloud builds submit "$STAGING_DIR" \
	--tag "$IMAGE_REF" \
	--project "$PROJECT_ID" \
	$QUIET_FLAG

# ── Deploy to Cloud Run ───────────────────────────────────────
echo -e "${BLUE}Deploying to Cloud Run...${NC}"
gcloud run deploy "${SERVICE_NAME}" \
  --image="$IMAGE_REF" \
  --platform=managed \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --allow-unauthenticated \
  --memory=512Mi \
  --cpu=1 \
  --min-instances=0 \
  --max-instances=10 \
  --port=8080 \
  --set-env-vars="$ENV_VARS" \
  $QUIET_FLAG

# ── Print service URL ─────────────────────────────────────────
SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" \
  --platform=managed \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format='value(status.url)')

echo ""
echo -e "${GREEN}✓ Deployment successful!${NC}"
echo -e "${GREEN}  Image:       ${IMAGE_REF}${NC}"
echo -e "${GREEN}  Service URL: ${SERVICE_URL}${NC}"

echo -e "${BLUE}Verifying health endpoint...${NC}"
curl -fsS "${SERVICE_URL}/health" > /dev/null
echo -e "${GREEN}  Health check passed${NC}"

cleanup_old_gcr_images
cleanup_old_build_records
