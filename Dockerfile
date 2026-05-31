# Build stage
FROM golang:1.24-alpine AS builder

# Install only the dependencies required for module download and build.
RUN apk add --no-cache git

WORKDIR /app

# Copy go mod files
COPY go.mod go.sum ./

# Download dependencies
RUN go mod download

# Copy source code
COPY . .

# Build the application statically without forcing a full rebuild on every deploy.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-w -s" -o /app/server ./cmd/server

# Final stage: distroless
# Using static-debian12 as it contains SSL certificates and tzdata but no shell/package manager.
FROM gcr.io/distroless/static-debian12:latest

WORKDIR /

# Copy the binary and config folder from builder
COPY --from=builder /app/server /server
COPY --from=builder /app/config /config

# Expose HTTP and gRPC ports
EXPOSE 8080 9090

# Required env vars at runtime:
#   GCS_STATIC_BUCKET  — GCS bucket name for static files (e.g. starkindustries-og-static-an1)
#   FIREBASE_PROJECT_ID — Firebase project ID
#   ENVIRONMENT        — "production" | "development"
CMD ["/server"]
