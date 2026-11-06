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
#
# Safety checks (both before anything is built):
#   - APP_ROOT must be a clean git checkout: the build context is rsynced from
#     the working tree, so uncommitted files would ship under a commit id that
#     doesn't contain them. ALLOW_DIRTY=true overrides.
#   - Rollback guard: the commit Cloud Run runs now (read from its image tag,
#     "<sha>-<timestamp>") must be contained in APP_ROOT's HEAD. Otherwise
#     deploying would drop whatever production has that HEAD lacks, e.g. a
#     feature branch deployed by hand. FORCE=true overrides.
#
# Normally this runs from CI: a push to insta-scraper-backend main calls
# infra's backend-deploy-reusable.yml, which runs the tests and then this.
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
ENV_VARS="${DEPLOY_ENV_VARS:-HTTP_PORT=8080,GRPC_PORT=9090,ENVIRONMENT=production,FIREBASE_PROJECT_ID=starkindustries-og,GCS_STATIC_BUCKET=starkindustries-og-static-an1,QRIT_CHAT_ARCHIVE_BUCKET=starkindustries-og-qrit-chat-archives-an1,QRIT_EMAIL_FROM=QRIT <qr@sachside.com>}"
QRIT_CHAT_ARCHIVE_JOB="${QRIT_CHAT_ARCHIVE_JOB:-qrit-chat-archive}"
CLOUD_RUN_MIN_INSTANCES="${CLOUD_RUN_MIN_INSTANCES:-0}"
CLOUD_RUN_MAX_INSTANCES="${CLOUD_RUN_MAX_INSTANCES:-50}"
KEEP_IMAGE_DIGESTS="${KEEP_IMAGE_DIGESTS:-2}"
KEEP_BUILD_RECORDS="${KEEP_BUILD_RECORDS:-2}"
CLEANUP_OLD_IMAGES="${CLEANUP_OLD_IMAGES:-true}"
CLEANUP_OLD_BUILDS="${CLEANUP_OLD_BUILDS:-true}"
FORCE="${FORCE:-false}"
ALLOW_DIRTY="${ALLOW_DIRTY:-false}"
# Streaming Cloud Build logs needs project Viewer; CI sets BUILD_LOGS=false.
BUILD_LOGS="${BUILD_LOGS:-true}"
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

# ── Source checks: clean checkout, no rollback ────────────────
IN_GIT=false
if command -v git &> /dev/null && git -C "$APP_ROOT" rev-parse --is-inside-work-tree &> /dev/null; then
  IN_GIT=true
fi

if [[ "$IN_GIT" == "true" ]]; then
  DIRTY="$(git -C "$APP_ROOT" status --porcelain)"
  if [[ -n "$DIRTY" ]]; then
    if [[ "$ALLOW_DIRTY" == "true" ]]; then
      echo -e "${BLUE}ALLOW_DIRTY=true: deploying uncommitted changes in ${APP_ROOT}.${NC}"
    else
      echo -e "${RED}Error: ${APP_ROOT} has uncommitted changes, which would be built and deployed:${NC}"
      printf '%s\n' "$DIRTY" | head -20 | sed 's/^/  /'
      echo -e "${RED}Commit or stash them, deploy from a clean worktree, or set ALLOW_DIRTY=true.${NC}"
      exit 1
    fi
  fi
elif [[ "$FORCE" != "true" ]]; then
  echo -e "${RED}Error: ${APP_ROOT} is not a git checkout, so the rollback guard can't run. Set FORCE=true to deploy anyway.${NC}"
  exit 1
fi

if ! command -v gcloud &> /dev/null; then
  echo -e "${RED}Error: gcloud CLI not installed${NC}"
  exit 1
fi
if ! LIVE_IMAGE="$(gcloud run services describe "${SERVICE_NAME}" \
  --platform=managed --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(spec.template.spec.containers[0].image)' 2>&1)"; then
  if [[ "$FORCE" != "true" ]]; then
    echo -e "${RED}Error: can't read the live service ${SERVICE_NAME}, so the rollback guard can't run:${NC}"
    printf '%s\n' "$LIVE_IMAGE" | tail -3 | sed 's/^/  /'
    echo -e "${RED}Set FORCE=true to deploy anyway (e.g. to create the service).${NC}"
    exit 1
  fi
  LIVE_IMAGE=""
fi
LIVE_TAG="${LIVE_IMAGE##*:}"
LIVE_COMMIT="${LIVE_TAG%%-*}"
if [[ -z "$LIVE_IMAGE" ]]; then
  echo -e "${BLUE}FORCE=true: no live service to compare against; skipping the rollback guard.${NC}"
elif [[ ! "$LIVE_COMMIT" =~ ^[0-9a-f]{7,40}$ ]]; then
  echo -e "${BLUE}Live image ${LIVE_IMAGE} carries no commit in its tag; skipping the rollback guard.${NC}"
elif [[ "$IN_GIT" == "true" ]]; then
  if ! git -C "$APP_ROOT" cat-file -e "${LIVE_COMMIT}^{commit}" 2>/dev/null; then
    if [[ "$FORCE" == "true" ]]; then
      echo -e "${BLUE}FORCE=true: live runs ${LIVE_COMMIT}, which ${APP_ROOT} doesn't contain. Deploying anyway.${NC}"
    else
      echo -e "${RED}Error: production runs ${LIVE_COMMIT} (${LIVE_IMAGE}), which isn't in ${APP_ROOT}.${NC}"
      echo -e "${RED}Fetch all branches (git fetch --all) and merge it, or set FORCE=true to replace it.${NC}"
      exit 1
    fi
  elif ! git -C "$APP_ROOT" merge-base --is-ancestor "$LIVE_COMMIT" HEAD; then
    MISSING="$(git -C "$APP_ROOT" log --format='%h %s' "HEAD..${LIVE_COMMIT}" | head -20)"
    if [[ "$FORCE" == "true" ]]; then
      echo -e "${BLUE}FORCE=true: rolling back these commits from production:${NC}"
      printf '%s\n' "$MISSING" | sed 's/^/  /'
    else
      echo -e "${RED}Error: production runs ${LIVE_COMMIT}, and deploying $(git -C "$APP_ROOT" rev-parse --short HEAD) would drop these commits:${NC}"
      printf '%s\n' "$MISSING" | sed 's/^/  /'
      echo -e "${RED}Merge them into this branch first, or set FORCE=true to roll back on purpose.${NC}"
      exit 1
    fi
  else
    echo -e "${GREEN}Rollback guard: live ${LIVE_COMMIT} is contained in $(git -C "$APP_ROOT" rev-parse --short HEAD).${NC}"
  fi
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
BUILD_LOG_FLAG=""
if [[ "$BUILD_LOGS" == "false" ]]; then
	BUILD_LOG_FLAG="--suppress-logs"
	echo -e "${BLUE}  (logs: https://console.cloud.google.com/cloud-build/builds?project=${PROJECT_ID})${NC}"
fi
gcloud builds submit "$STAGING_DIR" \
	--tag "$IMAGE_REF" \
	--project "$PROJECT_ID" \
	$BUILD_LOG_FLAG \
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
  --min-instances="${CLOUD_RUN_MIN_INSTANCES}" \
  --max-instances="${CLOUD_RUN_MAX_INSTANCES}" \
  --port=8080 \
  --update-env-vars="$ENV_VARS" \
  $QUIET_FLAG

# Keep a single production target: remove preview tags and follow the latest revision.
gcloud run services update-traffic "${SERVICE_NAME}" \
  --platform=managed \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --clear-tags \
  --to-latest \
  $QUIET_FLAG

# Keep the archive compactor on the exact backend image. Secret bindings and
# other job settings are managed by Terraform and remain unchanged.
if gcloud run jobs describe "${QRIT_CHAT_ARCHIVE_JOB}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo -e "${BLUE}Updating QRIT archive job image...${NC}"
  gcloud run jobs update "${QRIT_CHAT_ARCHIVE_JOB}" \
    --image="$IMAGE_REF" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    $QUIET_FLAG
fi

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

SERVING_IMAGE="$(gcloud run services describe "${SERVICE_NAME}" \
  --platform=managed --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(spec.template.spec.containers[0].image)')"
if [[ "$SERVING_IMAGE" != "$IMAGE_REF" ]]; then
  echo -e "${RED}Error: Cloud Run reports ${SERVING_IMAGE}, expected ${IMAGE_REF}.${NC}"
  exit 1
fi
echo -e "${GREEN}  Serving ${IMAGE_REF}${NC}"

# Housekeeping must never fail a deploy that already succeeded.
cleanup_old_gcr_images || echo -e "${BLUE}Warning: image cleanup failed (see above); continuing.${NC}"
cleanup_old_build_records || echo -e "${BLUE}Warning: build-record cleanup failed (see above); continuing.${NC}"
