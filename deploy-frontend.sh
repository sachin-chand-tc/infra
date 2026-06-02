#!/bin/bash
# =============================================================
# deploy-frontend.sh — Pack & upload a webinputs site to GCS
# =============================================================
# Lives in: infra/
# Sites source: ../webinputs/<site-name>/  (sibling repo)
#
# Usage:
#   ./deploy-frontend.sh --site apnijodi
#   ./deploy-frontend.sh --site planner --redeploy
#   ./deploy-frontend.sh --site sachins --redeploy
#   ./deploy-frontend.sh --site instascraper --dry-run
#
# Flags:
#   --site <name>    [required] Site folder name under webinputs/
#   --redeploy       Force Cloud Run to fetch the new files immediately
#   --dry-run        Pack and verify, skip upload
# =============================================================

set -euo pipefail

# ── Colours ─────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ── Defaults (override via env) ──────────────────────────────────
GCP_PROJECT_ID="${GCP_PROJECT_ID:-starkindustries-og}"
GCS_BUCKET="${GCS_BUCKET:-starkindustries-og-static-an1}"
CLOUD_RUN_SERVICE="${CLOUD_RUN_SERVICE:-feedseeker-website}"
REGION="${REGION:-asia-northeast1}"
MAX_ARCHIVE_MB="${MAX_ARCHIVE_MB:-150}"

SITE_NAME=""
REDEPLOY=false
DRY_RUN=false

# ── Parse flags ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site)      SITE_NAME="$2"; shift 2 ;;
    --redeploy)  REDEPLOY=true;  shift   ;;
    --dry-run)   DRY_RUN=true;   shift   ;;
    *) echo -e "${RED}Unknown flag: $1${NC}"; exit 1 ;;
  esac
done

if [[ -z "$SITE_NAME" ]]; then
  echo -e "${RED}Error: --site <name> is required${NC}"
  echo "  Example: ./deploy-frontend.sh --site apnijodi"
  exit 1
fi

# ── Resolve paths ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "${WEBINPUTS_ROOT:-}" ]]; then
  WEBINPUTS_ROOT="$(cd "$WEBINPUTS_ROOT" && pwd)"
else
  WEBINPUTS_ROOT="$(cd "$SCRIPT_DIR/../webinputs" && pwd)"
fi
SITE_DIR="$WEBINPUTS_ROOT/$SITE_NAME"

ARCHIVE_NAME="${SITE_NAME}.tar.gz"
GCS_PATH="gs://${GCS_BUCKET}/${ARCHIVE_NAME}"

if [[ ! -d "$SITE_DIR" ]]; then
  echo -e "${RED}Error: site not found: ${SITE_DIR}${NC}"
  echo "  Available sites:"
  ls -d "$WEBINPUTS_ROOT"/*/  2>/dev/null | xargs -I{} basename {} | grep -v infra | sed 's/^/    /'
  exit 1
fi

if grep -R --line-number --exclude-dir=.git --exclude-dir=node_modules '<<<<<<< \|=======\|>>>>>>> ' "$SITE_DIR" >/dev/null 2>&1; then
  echo -e "${RED}Error: merge conflict markers detected under ${SITE_DIR}${NC}"
  exit 1
fi

if find "$SITE_DIR" -type f \( -name '*.mov' -o -name '*.MOV' -o -name '*.mp4' -o -name '*.MP4' \) | grep -q .; then
  echo -e "${RED}Error: video artifacts detected in ${SITE_NAME}. Remove media artifacts before deploy.${NC}"
  find "$SITE_DIR" -type f \( -name '*.mov' -o -name '*.MOV' -o -name '*.mp4' -o -name '*.MP4' \) | sed 's/^/  - /'
  exit 1
fi

# ── Pre-flight ───────────────────────────────────────────────────
echo -e "${BLUE}══════════════════════════════════════════════${NC}"
echo -e "${BLUE}  deploy-frontend — ${SITE_NAME}${NC}"
echo -e "${BLUE}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}Source:     ${SITE_DIR}${NC}"
echo -e "${GREEN}GCS target: ${GCS_PATH}${NC}"
echo -e "${GREEN}Project:    ${GCP_PROJECT_ID}${NC}"
[[ "$DRY_RUN" == "true" ]] && echo -e "${YELLOW}Mode:       DRY RUN (no upload)${NC}"
echo ""

if ! command -v gsutil &> /dev/null; then
  echo -e "${RED}Error: gsutil not found (install gcloud SDK)${NC}"
  exit 1
fi

# ── Create tarball ───────────────────────────────────────────────
echo -e "${BLUE}Creating archive...${NC}"
TMPFILE=$(mktemp /tmp/webinputs-${SITE_NAME}-XXXXXX.tar.gz)
TMPSTAGE=$(mktemp -d /tmp/webinputs-stage-XXXXXX)
trap "rm -f '$TMPFILE'; rm -rf '$TMPSTAGE'" EXIT

# Copy site files to root of staging dir
rsync -a --exclude='.DS_Store' --exclude='.git' --exclude='node_modules' \
  --exclude='*.mov' --exclude='*.MOV' --exclude='*.mp4' --exclude='*.MP4' \
  --exclude='*.zip' --exclude='*.tar' --exclude='*.tar.gz' --exclude='*.tgz' \
  --exclude='assets/artifacts' \
  --exclude='*.md' --exclude='*.sh' --exclude='firebase.json' --exclude='firestore.rules' \
  "$SITE_DIR/" "$TMPSTAGE/"

# Copy common/ as a subfolder so imports like ../common/auth/google.js resolve correctly
rsync -a --exclude='.DS_Store' --exclude='.git' --exclude='node_modules' \
  --exclude='*.mov' --exclude='*.MOV' --exclude='*.mp4' --exclude='*.MP4' \
  --exclude='assets/artifacts' \
  "$WEBINPUTS_ROOT/common/" "$TMPSTAGE/common/"

tar -czf "$TMPFILE" -C "$TMPSTAGE" .

FILESIZE=$(du -h "$TMPFILE" | cut -f1)
echo -e "${GREEN}✓ Archive: ${FILESIZE}${NC}"

ARCHIVE_SIZE_MB=$(du -m "$TMPFILE" | cut -f1)
if [[ "$ARCHIVE_SIZE_MB" -gt "$MAX_ARCHIVE_MB" ]]; then
  echo -e "${RED}Error: archive size ${ARCHIVE_SIZE_MB}MB exceeds MAX_ARCHIVE_MB=${MAX_ARCHIVE_MB}${NC}"
  exit 1
fi

# ── Upload ───────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo -e "${YELLOW}[DRY RUN] Would upload to ${GCS_PATH}${NC}"
  echo -e "${YELLOW}[DRY RUN] Done — no files changed.${NC}"
  exit 0
fi

echo -e "${BLUE}Uploading to ${GCS_PATH}...${NC}"
gsutil -h "Cache-Control:no-cache,max-age=0" cp "$TMPFILE" "$GCS_PATH"
echo -e "${GREEN}✓ Upload complete${NC}"

# ── Redeploy Cloud Run ───────────────────────────────────────────
if [[ "$REDEPLOY" == "true" ]]; then
  echo ""
  echo -e "${BLUE}Redeploying Cloud Run: ${CLOUD_RUN_SERVICE} (${REGION})...${NC}"
  gcloud run services update "$CLOUD_RUN_SERVICE" \
    --project="$GCP_PROJECT_ID" \
    --region="$REGION" \
    --update-env-vars="DEPLOY_TIMESTAMP=$(date +%s)" \
    --quiet
  echo -e "${GREEN}✓ Cloud Run redeployed — fetching fresh files${NC}"
else
  echo ""
  echo -e "${YELLOW}Tip: add --redeploy to force Cloud Run to pick up the new files immediately.${NC}"
fi

echo ""
echo -e "${GREEN}✓ Done! ${SITE_NAME} deployed.${NC}"
