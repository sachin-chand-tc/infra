# infra — Deployment Guide

This repo is the single source of truth for all infrastructure and deployment logic.
It contains scripts, CI/CD pipelines, Docker configs, and Kubernetes manifests
for the following services:

| Repo | What it is |
|------|-----------|
| `insta-scraper-backend` | Go server — serves all websites via host-based routing |
| `webinputs` | Static frontend sites (`apnijodi`, `sachside`, `qrit`, …) |
| `qrit` | React owner dashboard — live at `qr.sachside.com` |

---

## Repository Layout

```
infra/
├── .github/workflows/
│   ├── backend-deploy-reusable.yml   Backend test + guarded deploy (called by insta-scraper-backend)
│   ├── frontend-publish-reusable.yml Frontend publish (called by webinputs)
│   └── tests.yml                     Tests for the deploy scripts
├── well-known/
│   └── assetlinks.json           Android App Links config (serve at /.well-known/assetlinks.json)
├── Dockerfile                    Docker build spec for the Go server
├── Makefile                      Convenience targets
├── deploy-backend.sh             Build & deploy Go server → Cloud Run
├── deploy-frontend.sh            Package & upload a static site → GCS
├── scripts/setup-backend-ci.sh   One-time: let insta-scraper-backend deploy itself
├── tests/                        deploy-*.test.sh (stub gcloud, no cloud access)
├── docker-compose.yml            Local dev environment
├── k8s/                          Kubernetes manifests
└── prometheus.yml                Metrics scrape config
```

---

## Prerequisites

Install the following tools before running any script:

```bash
# Google Cloud SDK (includes gcloud + gsutil)
brew install --cask google-cloud-sdk

# Authenticate
gcloud auth login
gcloud auth application-default login
```

---

## 1 · Deploy the Backend Server

`deploy-backend.sh` stages a clean build context from
`../insta-scraper-backend/`, builds the image in Google Cloud Build using
`infra/Dockerfile`, and deploys an immutable image tag to Cloud Run.

### Basic deploy

```bash
cd ~/code/repos/infra
GCP_PROJECT_ID=starkindustries-og ./deploy-backend.sh
```

### With environment variable pre-set

```bash
export GCP_PROJECT_ID=starkindustries-og
./deploy-backend.sh
```

### What it does (step-by-step)

1. Resolves `../insta-scraper-backend/` as the Go source root
2. Stages the app source plus `infra/Dockerfile` into a temporary build context
3. Runs `gcloud builds submit` so local Docker is not required
4. Tags the image immutably and deploys that exact image to Cloud Run
5. Sets env vars: `HTTP_PORT`, `GRPC_PORT`, `ENVIRONMENT`, `GCS_STATIC_BUCKET`
6. Prints the live service URL and verifies `/health`
7. Prunes older image digests and Cloud Build records with configurable retention

### Environment variables (all optional — have defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `GCP_PROJECT_ID` | _(prompted)_ | GCP project |
| `APP_ROOT` | `../insta-scraper-backend` | App source to stage into Cloud Build |
| `CLOUD_RUN_SERVICE` | `feedseeker-website` | Cloud Run service name |
| `REGION` | `asia-northeast1` | GCP region |
| `IMAGE_TAG` | auto-generated | Immutable image tag |
| `DEPLOY_ENV_VARS` | built-in defaults | Cloud Run env vars passed at deploy time |
| `KEEP_IMAGE_DIGESTS` | `2` | Number of recent image digests to retain in GCR |
| `KEEP_BUILD_RECORDS` | `2` | Number of recent Cloud Build records to retain |
| `CLEANUP_OLD_IMAGES` | `true` | Whether to delete older GCR image digests after deploy |
| `CLEANUP_OLD_BUILDS` | `true` | Whether to delete older Cloud Build records after deploy |

---

## 2 · Deploy a Frontend Site

`deploy-frontend.sh` tarballs a site folder from `../webinputs/<site>/` (plus
`common/`) and uploads it to GCS. **That's the whole deploy.** The Go server
checks every archive's GCS generation every 15 s and swaps in any that
changed, atomically, without a restart. No Cloud Run redeploy is needed.

Every upload records where it came from:
- GCS metadata on the archive: `commit`, `source_tree`, `ref`, `run_url`, `published_at`
- `__deploy.json` inside it, served at `https://<site host>/__deploy.json` (never cached)

**Rollback guard.** Before uploading, the script compares the live archive's
commit with yours. If the live site has commits touching `<site>/` or
`common/` that your checkout lacks (for example, a branch published by hand
that main never got), it refuses and lists them. `--force` overrides, for a
deliberate rollback.

### Available sites

| Site name | Archive | Domain |
|-----------|---------|--------|
| `apnijodi` | `apnijodi.tar.gz` | apnijodi.com |
| `planner` | `planner.tar.gz` | planner.sachside.com (also app.sachside.com) |
| `sachins` | `sachins.tar.gz` | sachins.sachside.com |
| `fifa` | `fifa.tar.gz` | fifa.sachside.com |
| `instascraper` | `insta-scraper.tar.gz` | feedseeker.com |
| `qrit` | `qrit.tar.gz` | qr.sachside.com |
| `sachside` | `sachside.tar.gz` | sachside.com (the server redirects it to planner) |

The archive name must match `gcs_path` in the backend's `config/production.yaml`.

### Usually: let CI do it

Merging to webinputs `main` publishes every site whose source differs from
what's live. You can also run **Publish Frontends** by hand from the Actions
tab, on any branch (the guard still applies).

### By hand

```bash
cd ~/code/repos/infra
./deploy-frontend.sh --site planner --check                 # what's live vs this checkout
./deploy-frontend.sh --site planner --dry-run               # build the archive, list it, upload nothing
./deploy-frontend.sh --site planner --verify-url https://planner.sachside.com
```

The checkout must be clean (`--allow-dirty` overrides), and `WEBINPUTS_ROOT`
must be a git checkout, or else set `DEPLOY_COMMIT` and `DEPLOY_SOURCE_TREE`.

### All flags

| Flag | Description |
|------|-------------|
| `--site <name>` | **Required.** Site folder under `../webinputs/` |
| `--check` | Print the live state (`missing`, `unknown`, `current`, `ahead`, `behind`, `foreign`) and exit |
| `--dry-run` | Build and list the archive, skip the upload |
| `--verify-url <url>` | After upload, wait until `<url>/__deploy.json` shows this upload |
| `--force` | Publish even though it rolls back live changes |
| `--allow-dirty` | Publish with uncommitted changes in the site or `common/` |
| `--redeploy` | Deprecated: also forces a new Cloud Run revision |

### Environment variables (all optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `WEBINPUTS_ROOT` | `../webinputs` | webinputs checkout to publish from |
| `GCP_PROJECT_ID` | `starkindustries-og` | GCP project |
| `GCS_BUCKET` | `starkindustries-og-static-an1` | Target GCS bucket |
| `GCS_OBJECT_NAME` | per the table above | Archive name without `.tar.gz` |
| `VERIFY_TIMEOUT` | `300` | Seconds `--verify-url` waits |

Tests: `bash tests/deploy-frontend.test.sh`.

---

## 3 · CI/CD (GitHub Actions)

### Frontends: webinputs → `frontend-publish-reusable.yml`

webinputs' **Publish Frontends** workflow plans each run from live state, not
from the push's diff:

| Live archive | On push to main |
|---|---|
| built from the same source (`current`) | skip |
| older than main (`ahead`) | publish |
| no metadata yet (`unknown`) | publish if the push changed the site |
| has site commits main lacks (`behind`, `foreign`) | **block**: the run fails and lists the commits |

A cancelled or failed run can't lose a publish: the next run sees the
difference and publishes it. Each publish waits until the live site serves
the new `__deploy.json`. The reusable workflow needs only `GCP_SA_KEY`;
webinputs is read with the caller's token and this repo is public.

### Backend: insta-scraper-backend → `backend-deploy-reusable.yml`

insta-scraper-backend's `.github/workflows/deploy.yml` calls it:
- pull request: `go build` + `go test`
- push to `main`: tests, then `deploy-backend.sh` for that commit
- manual run (any branch): tests, then a deploy unless `dry_run`; `force` allows a rollback

`deploy-backend.sh` refuses to deploy if Cloud Run's current image (tag
`<sha>-<timestamp>`) holds a commit the new one lacks, or if the checkout has
uncommitted or untracked files. `FORCE=true` / `ALLOW_DIRTY=true` override.
Pushing to *this* repo deploys nothing.

**One-time setup** (needs a project owner): `bash scripts/setup-backend-ci.sh`.
It gives the `github-actions` service account Cloud Build Editor and stores a
key as the backend repo's `GCP_SA_KEY` secret.

---

## 4 · Local Development

Run the entire stack locally with Docker Compose:

```bash
cd ~/code/repos/infra
docker-compose up
```

This starts the Go server on port `8080` and Prometheus on `9090`.

---

## 5 · Architecture Overview

```
┌─────────────┐    git push     ┌────────────────────────┐
│  Developer  │ ─────────────▶  │  infra GitHub Actions  │
└─────────────┘                 │  (test → build → deploy)│
                                └──────────┬─────────────┘
                                           │ docker push
                                           ▼
                                   gcr.io/.../feedseeker-website
                                           │ gcloud run deploy
                                           ▼
                              ┌────────────────────────────┐
                              │  Cloud Run: feedseeker-website │
                              │  (asia-northeast1)          │
                              └────────────┬───────────────┘
                                           │ on startup: downloads tarballs
                                           ▼
                              ┌────────────────────────────┐
                              │  GCS: starkindustries-og-  │
                              │  static-an1/               │
                              │   ├── apnijodi.tar.gz      │
                              │   ├── sachside.tar.gz      │
                              │   └── instascraper.tar.gz  │
                              └────────────────────────────┘
                                           │ host-based routing
                                    ┌──────┼──────┐
                                    ▼      ▼      ▼
                              apnijodi sachside feedseeker
                              .com     .com     .com
```

The Go server matches the HTTP `Host` header to the correct extracted
site folder and serves it as a static file tree with gzip, cache headers,
and security headers applied automatically.

---

## GitHub Secrets Required

| Repo | Secret | Description |
|---|---|---|
| webinputs | `GCP_SA_KEY` | Key for `gha-frontend-publisher` (object admin on the static bucket) |
| insta-scraper-backend | `GCP_SA_KEY` | Key for `github-actions` (Cloud Build, Cloud Run, GCR); see `scripts/setup-backend-ci.sh` |

`PAT_TOKEN` is no longer needed by either pipeline.

---

## Android App Links (`well-known/assetlinks.json`)

The file at `infra/well-known/assetlinks.json` must be served at:
```
https://qr.sachside.com/.well-known/assetlinks.json
```

This tells Android to auto-open the Qrit native app (when installed) instead of the browser.
Update `PENDING_RELEASE_KEYSTORE_SHA256` with the actual SHA-256 fingerprint from the release keystore when the Android app is published.
