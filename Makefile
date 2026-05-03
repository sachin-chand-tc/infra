.PHONY: help proto build test run docker-build docker-push deploy-cloudrun clean

# Variables
PROJECT_ID ?= your-gcp-project-id
IMAGE_NAME = gcr.io/$(PROJECT_ID)/insta-scraper-backend
VERSION ?= latest

help: ## Display this help screen
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

proto: ## Generate proto files
	@echo "Generating proto files..."
	protoc --go_out=. --go_opt=paths=source_relative \
		--go-grpc_out=. --go-grpc_opt=paths=source_relative \
		pkg/proto/*.proto

deps: ## Download dependencies
	@echo "Downloading dependencies..."
	go mod download
	go mod tidy

build: ## Build the application
	@echo "Building application..."
	go build -o bin/server ./cmd/server

test: ## Run tests
	@echo "Running tests..."
	go test -v ./...

run: ## Run the application locally
	@echo "Running application..."
	go run ./cmd/server

docker-build: ## Build Docker image
	@echo "Building Docker image..."
	docker build -t $(IMAGE_NAME):$(VERSION) .

docker-push: docker-build ## Push Docker image to GCR
	@echo "Pushing Docker image to GCR..."
	docker push $(IMAGE_NAME):$(VERSION)

deploy-cloudrun: docker-push ## Deploy to Google Cloud Run
	@echo "Deploying to Cloud Run..."
	../infra/deploy-backend.sh

clean: ## Clean build artifacts
	@echo "Cleaning..."
	rm -rf bin/
	go clean

lint: ## Run linter
	@echo "Running linter..."
	golangci-lint run ./...

fmt: ## Format code
	@echo "Formatting code..."
	go fmt ./...
	gofmt -s -w .
