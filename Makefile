SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

MODULE       := ping-pong-game
BIN_DIR      := bin
BINARY       := $(BIN_DIR)/echo-pong
LOCAL_IMAGE  := ping-pong-game:kind-local
KIND_CLUSTER := echo-pong
NAMESPACE    := echo-pong
KUBECTX      := kind-$(KIND_CLUSTER)
K8S_VERSION  := 1.31.0
SECRET_FILE  := k8s/overlays/kind/.secret.local

export PATH := $(HOME)/.local/bin:$(HOME)/.local/go/bin:$(HOME)/go/bin:$(PATH)

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

## --- versions ------------------------------------------------------------

.PHONY: tool-versions
tool-versions: ## Print every tool version this Makefile depends on
	@echo "go:             $$(go version)"
	@echo "git:            $$(git --version)"
	@echo "gh:              $$(gh --version | head -1)"
	@echo "docker:         $$(docker --version)"
	@echo "buildx:         $$(docker buildx version)"
	@echo "kubectl:        $$(kubectl version --client --output=yaml | grep gitVersion | head -1)"
	@echo "kind:           $$(kind version)"
	@echo "golangci-lint:  $$(golangci-lint --version | tail -1)"
	@echo "hadolint:       $$(hadolint --version)"
	@echo "actionlint:     $$(actionlint -version | head -1)"
	@echo "yamllint:       $$(yamllint --version)"
	@echo "kubeconform:    $$(kubeconform -v)"
	@echo "trivy:          $$(trivy --version | head -1)"

## --- go: fmt / lint / test -------------------------------------------------

.PHONY: fmt
fmt: ## Check gofmt formatting (fails on any unformatted file)
	@unformatted="$$(gofmt -l .)"; \
	if [ -n "$$unformatted" ]; then \
		echo "The following files are not gofmt-formatted:"; \
		echo "$$unformatted"; \
		exit 1; \
	fi
	@echo "gofmt: OK"

.PHONY: fmt-fix
fmt-fix: ## Auto-format Go source in place
	gofmt -w .

.PHONY: vet
vet: ## Run go vet
	go vet ./...

.PHONY: lint
lint: vet ## Run go vet + golangci-lint
	golangci-lint run ./...

.PHONY: test
test: ## Run unit tests with the race detector
	go test ./... -race -cover

## --- go: build --------------------------------------------------------

.PHONY: build
build: ## Build the native Go binary into bin/
	mkdir -p $(BIN_DIR)
	CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o $(BINARY) .
	@echo "built $(BINARY)"

## --- docker -------------------------------------------------------------

.PHONY: image
image: ## Build a single-platform local image (docker load) tagged for Kind
	docker buildx build --load -t $(LOCAL_IMAGE) .

.PHONY: scan
scan: image ## Trivy-scan the local image; fails on any HIGH/CRITICAL finding
	trivy image --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed $(LOCAL_IMAGE)

## --- k8s manifest validation ----------------------------------------------

.PHONY: k8s-render
k8s-render: $(SECRET_FILE) ## Render base + kind overlay via kustomize
	mkdir -p $(BIN_DIR)
	kubectl kustomize k8s/base > $(BIN_DIR)/k8s-base.rendered.yaml
	kubectl kustomize k8s/overlays/kind > $(BIN_DIR)/k8s-kind.rendered.yaml

.PHONY: k8s-validate
k8s-validate: k8s-render ## Strict kubeconform validation of rendered manifests
	kubeconform -strict -kubernetes-version $(K8S_VERSION) -summary $(BIN_DIR)/k8s-base.rendered.yaml
	kubeconform -strict -kubernetes-version $(K8S_VERSION) -summary $(BIN_DIR)/k8s-kind.rendered.yaml

.PHONY: yaml-lint
yaml-lint: ## yamllint over k8s manifests and workflow files
	yamllint k8s/ .github/workflows/ hack/kind-config.yaml

.PHONY: docker-lint
docker-lint: ## hadolint over the Dockerfile
	hadolint Dockerfile

.PHONY: workflow-lint
workflow-lint: ## actionlint over GitHub Actions workflows
	actionlint

.PHONY: no-committed-secrets
# Matches common secret-shaped keys, not just "token:" -- a value under
# password/secret/apiKey/authToken etc. is just as real a leak, and a
# regex that only caught the one key name this app happens to use would
# give false confidence against every other key name.
SECRET_KEY_PATTERN := ^\s*(token|password|passwd|secret|api[_-]?key|auth[_-]?token|access[_-]?key|private[_-]?key|credential):\s*[A-Za-z0-9+/=_-]{20,}
no-committed-secrets: ## Fail if any tracked file looks like a real Secret value
	@if git grep -niE '$(SECRET_KEY_PATTERN)' -- ':!k8s/secret.example.yaml' | grep -q .; then \
		echo "Possible committed secret value found:"; \
		git grep -niE '$(SECRET_KEY_PATTERN)' -- ':!k8s/secret.example.yaml'; \
		exit 1; \
	fi
	@echo "no-committed-secrets: OK"

## --- umbrella targets -----------------------------------------------------

.PHONY: validate
validate: fmt lint test docker-lint workflow-lint yaml-lint k8s-validate no-committed-secrets ## Run every static check (mirrors CI exactly)
	@echo "validate: all checks passed"

## --- local Kind end-to-end ------------------------------------------------

.PHONY: kind-up
kind-up: ## Create the local Kind cluster and install ingress-nginx
	kind create cluster --name $(KIND_CLUSTER) --config hack/kind-config.yaml
	kubectl --context $(KUBECTX) apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml
	kubectl --context $(KUBECTX) -n ingress-nginx wait --for=condition=Ready pod \
		-l app.kubernetes.io/component=controller --timeout=180s

$(SECRET_FILE):
	@echo -n "kind-local-test-token-$$(date +%s)" > $(SECRET_FILE)
	@echo "generated throwaway local test secret at $(SECRET_FILE) (gitignored, never a real credential)"

.PHONY: deploy-local
deploy-local: image $(SECRET_FILE) ## Load the local image into Kind and apply manifests
	kind load docker-image $(LOCAL_IMAGE) --name $(KIND_CLUSTER)
	kubectl --context $(KUBECTX) apply -k k8s/overlays/kind
	kubectl --context $(KUBECTX) -n $(NAMESPACE) rollout status deploy/echo-pong --timeout=120s

.PHONY: e2e
e2e: ## Port-forward through the ingress controller and exercise every endpoint
	@bash hack/e2e.sh $(KUBECTX)

.PHONY: kind-down
kind-down: ## Delete the local Kind cluster and local test secret
	kind delete cluster --name $(KIND_CLUSTER) || true
	rm -f $(SECRET_FILE)

.PHONY: verify
verify: validate scan kind-up deploy-local e2e kind-down ## One-command full local verification (see docs/ARCHITECTURE.md)
	@echo "verify: complete"

.PHONY: clean
clean: ## Remove local build/render output
	rm -rf $(BIN_DIR)
