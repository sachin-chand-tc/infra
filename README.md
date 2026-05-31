# infra — Deployment Guide

This repo is the single source of truth for all infrastructure and deployment logic.
It contains scripts, CI/CD pipelines, Docker configs, and Kubernetes manifests
for the following services:

| Repo | What it is |
|------|-----------|
| `insta-scraper-backend` | Go server — serves all websites via host-based routing |
| `webinputs` | Static frontend sites (`apnijodi`, `sachside`, `instascraper`, …) |
| `qrit` | React frontend — upcoming app (backend will live in `insta-scraper-backend`) |

---

## Repository Layout

```
infra/
├── .github/workflows/ci-cd.yml   CI/CD for the backend server
├── Dockerfile                    Docker build spec for the Go server
├── Makefile                      Convenience targets
├── deploy-backend.sh             Build & deploy Go server → Cloud Run
├── deploy-frontend.sh            Package & upload a static site → GCS
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

`deploy-frontend.sh` tarballs a site folder from `../webinputs/<site>/`,
uploads it to GCS, and optionally restarts Cloud Run so it picks up the
fresh files immediately.

### Available sites

| Site name | Domain |
|-----------|--------|
| `apnijodi` | apnijodi.com |
| `planner` | planner.sachside.com (also app.sachside.com) |
| `sachins` | sachins.sachside.com |
| `instascraper` | feedseeker.com |

### Deploy a site (basic)

```bash
cd ~/code/repos/infra
./deploy-frontend.sh --site apnijodi
```

### Deploy and force Cloud Run to reload immediately

```bash
./deploy-frontend.sh --site apnijodi --redeploy
```

### Dry run — pack and verify without uploading

```bash
./deploy-frontend.sh --site apnijodi --dry-run
```

### Deploy all sites at once

```bash
for site in apnijodi planner sachins instascraper; do
  ./deploy-frontend.sh --site "$site" --redeploy
done
```

### All flags

| Flag | Description |
|------|-------------|
| `--site <name>` | **Required.** Site folder under `../webinputs/` |
| `--redeploy` | After upload, bumps `DEPLOY_TIMESTAMP` env var on Cloud Run to trigger a new revision |
| `--dry-run` | Creates the tarball and verifies it, but skips the GCS upload |

### Environment variables (all optional — have defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `GCP_PROJECT_ID` | `starkindustries-og` | GCP project |
| `GCS_BUCKET` | `starkindustries-og-static-an1` | Target GCS bucket |
| `CLOUD_RUN_SERVICE` | `feedseeker-website` | Cloud Run service to redeploy |
| `REGION` | `asia-northeast1` | GCP region |

### Override bucket (e.g. for staging)

```bash
GCS_BUCKET=my-staging-bucket ./deploy-frontend.sh --site apnijodi --dry-run
```

---

## 3 · CI/CD (GitHub Actions)

`.github/workflows/ci-cd.yml` runs automatically on every push to `main`
in **this** repo (infra). It:

1. Checks out `insta-scraper-backend` app source into `./app`
2. Runs Go tests against the app source
3. Calls the same `deploy-backend.sh` script used locally
4. Builds in Cloud Build and deploys to Cloud Run

### Required GitHub Secrets

Set these in the `infra` repo → Settings → Secrets → Actions:

| Secret | Description |
|--------|-------------|
| `GCP_SA_KEY` | JSON key for a GCP service account with Cloud Run + GCR permissions |
| `PAT_TOKEN` | GitHub Personal Access Token with `repo` scope (to checkout `insta-scraper-backend`) |
| `FIREBASE_PROJECT_ID` | Firebase project ID for the Go server |

### Trigger manually

You can also trigger CI from the GitHub Actions tab → select
**"CI/CD — Backend Server"** → **Run workflow**.

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
