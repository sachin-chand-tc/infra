#!/bin/bash
# =============================================================
# deploy-frontend.sh — Pack & upload a webinputs site to GCS
# =============================================================
# Lives in: infra/
# Sites source: ../webinputs/<site-name>/  (sibling repo)
#
# The Go server (feedseeker-website) checks GCS every 15 s and swaps in any
# archive whose generation changed, so an upload goes live on its own: no
# Cloud Run redeploy is needed. Use --verify-url to wait until it does.
#
# Every upload records the commit and source tree it was built from, as GCS
# metadata and as <site>/__deploy.json. Before uploading, the script refuses
# to replace a live site with a commit that is missing site changes the live
# one has (a rollback), unless --force is given.
#
# Usage:
#   ./deploy-frontend.sh --site planner
#   ./deploy-frontend.sh --site planner --verify-url https://planner.sachside.com
#   ./deploy-frontend.sh --site sachins --check        # report live state, change nothing
#   ./deploy-frontend.sh --site instascraper --dry-run
#
# Flags:
#   --site <name>       [required] Site folder name under webinputs/
#   --check             Print the live archive's state vs this checkout and exit
#   --dry-run           Pack and verify, skip upload
#   --force             Publish even if it would roll back live site changes
#   --allow-dirty       Publish with uncommitted changes in the site or common/
#   --verify-url <url>  After upload, wait until <url>/__deploy.json shows this upload
#   --redeploy          Deprecated and unnecessary: also forces a new Cloud Run revision
#
# Env:
#   WEBINPUTS_ROOT      webinputs checkout (default ../webinputs). If it is not a
#                       git checkout, set DEPLOY_COMMIT and DEPLOY_SOURCE_TREE or
#                       pass --force.
#   GCS_OBJECT_NAME     Archive name without .tar.gz (default: the server's name for the site)
#   DEPLOY_REF, DEPLOY_RUN_URL  Recorded in the metadata (CI sets them).
#   VERIFY_TIMEOUT      Seconds --verify-url waits (default 300).
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
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-300}"

SITE_NAME=""
REDEPLOY=false
DRY_RUN=false
CHECK_ONLY=false
FORCE=false
ALLOW_DIRTY=false
VERIFY_URL=""

# ── Parse flags ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site)        SITE_NAME="$2"; shift 2 ;;
    --redeploy)    REDEPLOY=true;  shift   ;;
    --dry-run)     DRY_RUN=true;   shift   ;;
    --check)       CHECK_ONLY=true; shift  ;;
    --force)       FORCE=true;     shift   ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    --verify-url)  VERIFY_URL="${2%/}"; shift 2 ;;
    *) echo -e "${RED}Unknown flag: $1${NC}" >&2; exit 1 ;;
  esac
done

if [[ -z "$SITE_NAME" ]]; then
  echo -e "${RED}Error: --site <name> is required${NC}" >&2
  echo "  Example: ./deploy-frontend.sh --site apnijodi" >&2
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

# The object the Go server reads for this site: gcs_path in
# insta-scraper-backend/config/production.yaml. Keep the two in step.
case "$SITE_NAME" in
  instascraper) DEFAULT_OBJECT="insta-scraper" ;;   # served at feedseeker.com
  *)            DEFAULT_OBJECT="$SITE_NAME" ;;
esac
ARCHIVE_NAME="${GCS_OBJECT_NAME:-$DEFAULT_OBJECT}.tar.gz"
GCS_PATH="gs://${GCS_BUCKET}/${ARCHIVE_NAME}"
MARKER_FILE="__deploy.json"

# ── Source: which commit and tree is being published ─────────────
IN_GIT=false
if git -C "$WEBINPUTS_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && [[ "$(cd "$(git -C "$WEBINPUTS_ROOT" rev-parse --show-toplevel)" && pwd -P)" == "$(cd "$WEBINPUTS_ROOT" && pwd -P)" ]]; then
  IN_GIT=true
fi

# Identifies the published content: the site folder's tree plus common/'s,
# since every archive bundles common/. Equal trees mean identical sources.
source_tree_of() {
  local rev="$1" site_tree common_tree
  site_tree="$(git -C "$WEBINPUTS_ROOT" rev-parse -q --verify "${rev}:${SITE_NAME}" 2>/dev/null || echo none)"
  common_tree="$(git -C "$WEBINPUTS_ROOT" rev-parse -q --verify "${rev}:common" 2>/dev/null || echo none)"
  echo "${site_tree}+${common_tree}"
}

SOURCE_DIRTY=false
if [[ "$IN_GIT" == "true" ]]; then
  SOURCE_COMMIT="$(git -C "$WEBINPUTS_ROOT" rev-parse HEAD)"
  SOURCE_TREE="$(source_tree_of HEAD)"
  if [[ -n "$(git -C "$WEBINPUTS_ROOT" status --porcelain -- "$SITE_NAME" common 2>/dev/null)" ]]; then
    SOURCE_DIRTY=true
  fi
  DEFAULT_REF="$(git -C "$WEBINPUTS_ROOT" rev-parse --abbrev-ref HEAD)"
else
  SOURCE_COMMIT="${DEPLOY_COMMIT:-}"
  SOURCE_TREE="${DEPLOY_SOURCE_TREE:-}"
  DEFAULT_REF="unknown"
fi
DEPLOY_REF="${DEPLOY_REF:-$DEFAULT_REF}"
DEPLOY_RUN_URL="${DEPLOY_RUN_URL:-local:$(whoami)@$(hostname -s 2>/dev/null || echo host)}"

# ── Live state: what the bucket serves now vs this checkout ──────
# Sets LIVE_COMMIT, LIVE_TREE and STATE, one of:
#   missing  no archive yet
#   unknown  archive has no source metadata (published before tracking)
#   current  live archive was built from the same source tree
#   ahead    this checkout contains everything live has for this site
#   behind   live has commits touching this site that this checkout lacks
#   foreign  live was built from a commit this checkout doesn't have
# MISSING_COMMITS lists the commits "behind" would roll back.
read_live_state() {
  LIVE_COMMIT=""; LIVE_TREE=""; MISSING_COMMITS=""
  local describe
  if ! describe="$(gcloud storage objects describe "$GCS_PATH" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null)"; then
    STATE=missing
    return
  fi
  eval "$(printf '%s' "$describe" | python3 -I -c '
import json, shlex, sys
d = json.load(sys.stdin)
m = d.get("custom_fields") or d.get("metadata") or {}
print("LIVE_COMMIT=" + shlex.quote(m.get("commit", "")))
print("LIVE_TREE=" + shlex.quote(m.get("source_tree", "")))
')"

  if [[ -z "$LIVE_COMMIT" || "$LIVE_COMMIT" == "unknown" ]]; then
    STATE=unknown
  elif [[ -n "$SOURCE_TREE" && "$LIVE_TREE" == "$SOURCE_TREE" ]]; then
    STATE=current
  elif [[ "$IN_GIT" != "true" ]]; then
    STATE=foreign
  elif ! git -C "$WEBINPUTS_ROOT" cat-file -e "${LIVE_COMMIT}^{commit}" 2>/dev/null; then
    STATE=foreign
  elif git -C "$WEBINPUTS_ROOT" merge-base --is-ancestor "$LIVE_COMMIT" HEAD; then
    STATE=ahead
  else
    MISSING_COMMITS="$(git -C "$WEBINPUTS_ROOT" log --format='%h %s' "HEAD..${LIVE_COMMIT}" -- "$SITE_NAME" common | head -20)"
    if [[ -z "$MISSING_COMMITS" ]]; then
      # Live has other commits, but none touch this site or common/.
      STATE=ahead
    else
      STATE=behind
    fi
  fi
}

print_state() {
  echo -e "${BLUE}Live ${ARCHIVE_NAME}: ${STATE}${NC} (live ${LIVE_COMMIT:-?}, this ${SOURCE_COMMIT:-?})" >&2
  if [[ -n "$MISSING_COMMITS" ]]; then
    echo -e "${YELLOW}Live has these ${SITE_NAME}/common commits that this checkout lacks:${NC}" >&2
    printf '%s\n' "$MISSING_COMMITS" | sed 's/^/  /' >&2
  fi
}

if [[ ! -d "$SITE_DIR" ]]; then
  echo -e "${RED}Error: site not found: ${SITE_DIR}${NC}" >&2
  echo "  Available sites:" >&2
  ls -d "$WEBINPUTS_ROOT"/*/  2>/dev/null | xargs -I{} basename {} | grep -v infra | sed 's/^/    /' >&2
  exit 1
fi

if [[ "$CHECK_ONLY" == "true" ]]; then
  read_live_state
  print_state
  echo "state=${STATE}"
  echo "live_commit=${LIVE_COMMIT}"
  echo "source_commit=${SOURCE_COMMIT}"
  echo "missing_commits=$(printf '%s' "$MISSING_COMMITS" | grep -c . || true)"
  exit 0
fi

if grep -R --line-number --exclude-dir=.git --exclude-dir=node_modules -E '^(<<<<<<< |=======|>>>>>>> )' "$SITE_DIR" >/dev/null 2>&1; then
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
echo -e "${GREEN}Commit:     ${SOURCE_COMMIT:-unknown} (${DEPLOY_REF})${NC}"
echo -e "${GREEN}GCS target: ${GCS_PATH}${NC}"
echo -e "${GREEN}Project:    ${GCP_PROJECT_ID}${NC}"
[[ "$DRY_RUN" == "true" ]] && echo -e "${YELLOW}Mode:       DRY RUN (no upload)${NC}"
echo ""

if ! command -v gcloud &> /dev/null; then
  echo -e "${RED}Error: gcloud not found (install the gcloud SDK)${NC}"
  exit 1
fi

# Uncommitted files would ship under a commit id that doesn't contain them.
# CI builds in place (and may move folders), so the check is local-only.
if [[ "$SOURCE_DIRTY" == "true" && "${CI:-}" != "true" && "$ALLOW_DIRTY" != "true" ]]; then
  echo -e "${RED}Error: uncommitted changes under ${SITE_NAME}/ or common/:${NC}"
  git -C "$WEBINPUTS_ROOT" status --short -- "$SITE_NAME" common | sed 's/^/  /'
  echo -e "${YELLOW}Commit them, or pass --allow-dirty to publish anyway.${NC}"
  exit 1
fi

if [[ -z "$SOURCE_COMMIT" && "$FORCE" != "true" ]]; then
  echo -e "${RED}Error: can't tell which commit ${WEBINPUTS_ROOT} holds (not a git checkout).${NC}"
  echo -e "${YELLOW}Set DEPLOY_COMMIT (and DEPLOY_SOURCE_TREE), or pass --force.${NC}"
  exit 1
fi

# ── Rollback guard ───────────────────────────────────────────────
read_live_state
print_state
case "$STATE" in
  behind|foreign)
    if [[ "$FORCE" == "true" ]]; then
      echo -e "${YELLOW}--force: publishing anyway; live changes this checkout lacks will disappear.${NC}"
    else
      echo -e "${RED}Error: publishing ${SOURCE_COMMIT:0:7} would roll ${SITE_NAME} back.${NC}"
      if [[ "$STATE" == "foreign" ]]; then
        echo -e "${YELLOW}Live was built from ${LIVE_COMMIT}, which this checkout doesn't contain (fetch it, or it came from an unpushed branch).${NC}"
      fi
      echo -e "${YELLOW}Merge the live commits into this branch first, or pass --force to roll back on purpose.${NC}"
      exit 1
    fi
    ;;
esac
echo ""

# ── Create tarball ───────────────────────────────────────────────
echo -e "${BLUE}Creating archive...${NC}"
TMPFILE=$(mktemp "${TMPDIR:-/tmp}/webinputs-${SITE_NAME}-XXXXXX")
TMPSTAGE=$(mktemp -d "${TMPDIR:-/tmp}/webinputs-stage-XXXXXX")
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

# Validate that built bundles required by index.html actually exist in the staged artifact.
# This prevents deploying shells that reference dist/main.js without a compiled bundle.
if [[ -f "$TMPSTAGE/index.html" ]] && grep -q 'dist/main\.js' "$TMPSTAGE/index.html"; then
  if [[ ! -f "$TMPSTAGE/dist/main.js" ]]; then
    echo -e "${RED}Error: index.html references dist/main.js, but dist/main.js is missing for site '${SITE_NAME}'.${NC}"
    echo -e "${YELLOW}Hint: build the site first (for example: cd $SITE_DIR && npm run build).${NC}"
    exit 1
  fi
fi

PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# The deploy marker, served at https://<host>/__deploy.json, says which commit
# a site runs. --verify-url polls it.
python3 -I -c '
import json, sys
keys = ["site", "commit", "source_tree", "ref", "run", "published_at"]
json.dump(dict(zip(keys, sys.argv[2:])), open(sys.argv[1], "w"), indent=2)
' "$TMPSTAGE/$MARKER_FILE" "$SITE_NAME" "${SOURCE_COMMIT:-unknown}" "${SOURCE_TREE:-unknown}" \
  "$DEPLOY_REF" "$DEPLOY_RUN_URL" "$PUBLISHED_AT"

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
  echo -e "${YELLOW}[DRY RUN] Archive contents:${NC}"
  tar -tzf "$TMPFILE" | sed 's|^\./||' | grep -v -e '/$' -e '^$' | sort | sed 's/^/  /'
  echo -e "${YELLOW}[DRY RUN] Would upload to ${GCS_PATH} with commit=${SOURCE_COMMIT:-unknown}${NC}"
  echo -e "${YELLOW}[DRY RUN] Done — no files changed.${NC}"
  exit 0
fi

echo -e "${BLUE}Uploading to ${GCS_PATH}...${NC}"
gcloud storage cp "$TMPFILE" "$GCS_PATH" \
  --project="$GCP_PROJECT_ID" \
  --cache-control="no-cache,max-age=0" \
  --content-type="application/gzip" \
  --custom-metadata="commit=${SOURCE_COMMIT:-unknown},source_tree=${SOURCE_TREE:-unknown},ref=${DEPLOY_REF//,/_},run_url=${DEPLOY_RUN_URL//,/_},published_at=${PUBLISHED_AT}"
echo -e "${GREEN}✓ Upload complete${NC}"

# ── Redeploy Cloud Run (deprecated) ──────────────────────────────
if [[ "$REDEPLOY" == "true" ]]; then
  echo ""
  echo -e "${YELLOW}--redeploy is no longer needed: the server picks up new archives by itself.${NC}"
  echo -e "${BLUE}Redeploying Cloud Run: ${CLOUD_RUN_SERVICE} (${REGION})...${NC}"
  max_attempts=6
  attempt=1
  while true; do
    set +e
    update_output=$(gcloud run services update "$CLOUD_RUN_SERVICE" \
      --project="$GCP_PROJECT_ID" \
      --region="$REGION" \
      --update-env-vars="DEPLOY_TIMESTAMP=$(date +%s)" \
      --quiet 2>&1)
    update_code=$?
    set -e

    if [[ $update_code -eq 0 ]]; then
      echo "$update_output"
      break
    fi

    if echo "$update_output" | grep -q "ABORTED: Conflict for resource" && [[ $attempt -lt $max_attempts ]]; then
      sleep_seconds=$((attempt * 4))
      echo -e "${YELLOW}Cloud Run update conflict detected (attempt ${attempt}/${max_attempts}). Retrying in ${sleep_seconds}s...${NC}"
      attempt=$((attempt + 1))
      sleep "$sleep_seconds"
      continue
    fi

    echo "$update_output"
    exit $update_code
  done
  echo -e "${GREEN}✓ Cloud Run redeployed${NC}"
fi

# ── Verify the live site serves this upload ──────────────────────
if [[ -n "$VERIFY_URL" ]]; then
  echo ""
  echo -e "${BLUE}Waiting for ${VERIFY_URL}/${MARKER_FILE} to show this upload (up to ${VERIFY_TIMEOUT}s)...${NC}"
  deadline=$(( $(date +%s) + VERIFY_TIMEOUT ))
  seen=""
  while true; do
    # A unique query string sidesteps any CDN or browser cache.
    body="$(curl -fsS --max-time 10 -A "webinputs-deploy-verify" "${VERIFY_URL}/${MARKER_FILE}?v=$(date +%s)${RANDOM}" 2>/dev/null || true)"
    seen="$(printf '%s' "$body" | python3 -I -c '
import json, sys
try:
    print(json.load(sys.stdin).get("published_at", ""))
except Exception:
    print("")
')"
    if [[ "$seen" == "$PUBLISHED_AT" ]]; then
      echo -e "${GREEN}✓ Live: ${VERIFY_URL} serves ${SOURCE_COMMIT:0:12} (published ${PUBLISHED_AT})${NC}"
      break
    fi
    if (( $(date +%s) >= deadline )); then
      echo -e "${RED}Error: after ${VERIFY_TIMEOUT}s ${VERIFY_URL} still doesn't serve this upload (marker published_at='${seen:-none}').${NC}"
      echo -e "${YELLOW}The archive is uploaded; check the server's 'Activated site archive' logs.${NC}"
      exit 1
    fi
    sleep 5
  done
fi

echo ""
echo -e "${GREEN}✓ Done! ${SITE_NAME} deployed.${NC}"
