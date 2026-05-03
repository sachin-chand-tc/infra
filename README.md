# infra — Deployment Guide

This repo is the single source of truth for all infrastructure and deployment logic.
It contains scripts, CI/CD pipelines, Docker configs, and Kubernetes manifests
for the following services:

| Repo | What it is |
|------|-----------|
| `insta-scraper-backend` | Go server — serves all websites via host-based routing |
| `webinputs` | Static frontend sites (`apnijodi`, `sachside`, `instascraper`, …) |

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

# Docker Desktop (for backend builds)
# https://docs.docker.com/get-docker/
```

---

## 1 · Deploy the Backend Server

`deploy-backend.sh` builds the Docker image from the Go source in
`../insta-scraper-backend/` using `infra/Dockerfile`, pushes it to GCR,
and deploys it to Cloud Run.

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
2. Builds a `linux/amd64` Docker image using `infra/Dockerfile`
3. Pushes the image to `gcr.io/<PROJECT_ID>/feedseeker-website:latest`
4. Deploys to Cloud Run (`feedseeker-website`) in `asia-northeast1`
5. Sets env vars: `HTTP_PORT`, `GRPC_PORT`, `ENVIRONMENT`, `GCS_STATIC_BUCKET`
6. Prints the live service URL

### Environment variables (all optional — have defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `GCP_PROJECT_ID` | _(prompted)_ | GCP project |

---

## 2 · Deploy a Frontend Site

`deploy-frontend.sh` tarballs a site folder from `../webinputs/<site>/`,
uploads it to GCS, and optionally restarts Cloud Run so it picks up the
fresh files immediately.

### Available sites

| Site name | Domain |
|-----------|--------|
| `apnijodi` | apnijodi.com |
| `sachside` | app.sachside.com |
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
for site in apnijodi sachside instascraper; do
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
3. Builds the Docker image using `infra/Dockerfile` with `./app` as build context
4. Pushes to GCR and deploys to Cloud Run

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
