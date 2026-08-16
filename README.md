# 🏓 DevOps Home Assignment: Ping-Pong Game Deployment

## 📋 Overview

**⏱️ Duration:** 2-3 hours  
**🎯 Objective:** Create a production-ready CI/CD pipeline that builds, containerizes, and deploys a Go application to Kubernetes.

---

## 🚀 Application

A Go HTTP server implementing a ping-pong game with these endpoints:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/ping` | GET | Returns "pong" message |
| `/pong` | GET | Returns "ping" message |
| `/health` | GET | Health check endpoint |
| `/` | GET | API documentation |

**Environment Variables:**
- `PORT` - Server port (default: 8080)
- `SECRET_FILE_PATH` - Path to secret file

**Run Modes:** `server` or `cli`

**Authentication:**
- `Authorization` header with secret token is required for `/ping` and `/pong` endpoints
- in CLI mode, the secret token is passed as a command line argument

**Note:**
- The server will think for 10 seconds before starting the server
- health check endpoint is available at `/health` and it will return 200 OK if the server is ready to serve requests
- The server will be available on the port specified in the `PORT` environment variable
- The server will read the secret token from the `SECRET_FILE_PATH` environment variable
- The secret token is passed as a command line argument in CLI mode

---

## 🎯 Mission

Take this application to production with support for both **x86** and **ARM64** architectures. Have a binary release and a container release available for developers and production.

---

## 📋 Requirements

### 🔒 Security
- [ ] No containers running as root
- [ ] All images must pass security scans
- [ ] No critical/high vulnerabilities should be released to production
- [ ] No secrets in codebase
- [ ] Proper filesystem isolation

### ☸️ Kubernetes
- [ ] Zero-downtime deployments server must be available and ready at all times
- [ ] ARM64 architecture preferred
- [ ] No direct internet access (use ingress/proxy)
- [ ] Cluster can pull from registry

### 🏗️ CI/CD
- [ ] Multi-architecture builds (x86/ARM64)
- [ ] Images stored in GitHub Container Registry
- [ ] Versioned releases with tags
- [ ] Both container and binary releases

---

## 🛠️ Environment

**Prerequisites:**
- Docker
- Minikube or Kind
- kubectl
- Go 1.24
- GitHub account

---

## 📊 Evaluation

### Technical Implementation
- Container Security
- Kubernetes Manifests and best practices
- CI/CD Pipeline container and binary releases
- Multi-Architecture builds 
- Security Scanning and release prevention for critical and high vulnerabilities

### Understanding & Explanation
- Architecture decisions
- Scaling strategy
- Cloud deployment considerations
- Security measures
- Maintaining image versions and tags and removing old ones

---

## 📝 Deliverables

- [ ] `Dockerfile`
- [ ] `k8s/` manifests
- [ ] `.github/workflows/` CI/CD pipeline
- [ ] Documentation of your approach

**Note:** Use Minikube/Kind for testing. Be prepared to explain real cloud deployment strategy.

## You will be asked to explain the following:
- The deployment strategy
- The scaling strategy
- The security measures
- The CI/CD pipeline
- The multi-architecture builds
- The versioning and tagging strategy
- Going cloud with EKS and how to deploy the application to EKS
- How to allow teams from across the world to pull the image fast using AWS solutions
- How to manage older and stale versions of the application

## Submission
- Create a fork of this repository and give access to your fork
- Once you notify that you are done no more commits!

---

**Good luck! 🚀**

---

## ✅ Solution

Everything below documents what was actually built for this assignment, in
this fork. The four required deliverables:

| Deliverable | Where |
|---|---|
| `Dockerfile` (multi-stage, distroless nonroot, multi-arch) | [`Dockerfile`](Dockerfile) |
| `k8s/` manifests (Namespace, Deployment, Service, Secret, ServiceAccount, NetworkPolicy, Ingress, PDB, HPA) | [`k8s/base/`](k8s/base/), local-only override in [`k8s/overlays/kind/`](k8s/overlays/kind/) |
| `.github/workflows/` CI/CD | [`ci.yml`](.github/workflows/ci.yml), [`go-checks.yml`](.github/workflows/go-checks.yml), [`release.yml`](.github/workflows/release.yml) |
| Written architecture/design docs | **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** — deployment strategy, scaling, security, CI/CD walkthrough, multi-arch builds, versioning, AWS EKS mapping, fast global pulls, image lifecycle |

> **One brief-vs-code discrepancy, followed as documented in
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md):** the brief above says the
> CLI's secret is "passed as a command line argument"; the actual code uses
> a named `--password` flag, not a bare positional argument. This solution
> follows the code.

### Beyond the assignment: a real AWS reference architecture

`docs/ARCHITECTURE.md` §7's "Cloud deployment on AWS EKS" section is
intentionally a summary. The full design — actually built as Terraform,
Helm, and reusable GitHub Actions workflows, not just described — lives in
three sibling repositories:

| Repository | Owns |
|---|---|
| [`echo-pong-infrastructure`](https://github.com/nevomenashe15-sketch/echo-pong-infrastructure) | AWS: VPC, EKS, ECR, IAM, KMS, Route 53/ACM, CloudFront, WAF, Secrets Manager metadata, and the Argo CD install. |
| [`echo-pong-gitops`](https://github.com/nevomenashe15-sketch/echo-pong-gitops) | Everything in the cluster after Argo CD exists: platform add-ons, Karpenter NodePools, the app's Helm release and Ingress. |
| [`echo-pong-workflows`](https://github.com/nevomenashe15-sketch/echo-pong-workflows) | Reusable `workflow_call` CI/CD logic those repos assume. Not yet wired into this repo's own `ci.yml`/`release.yml`, which stay self-contained for the assignment submission. |

### Local development

Requires Go 1.24.x, Docker with Buildx, `kind`, `kubectl`, and the linters
listed in `docs/ARCHITECTURE.md` — `make tool-versions` prints what's
actually detected.

```bash
make help        # list every target
make validate    # gofmt + go vet + golangci-lint + go test -race +
                  # hadolint + actionlint + yamllint + kubeconform +
                  # no-committed-secrets — the exact same checks CI runs
make build        # native Go binary -> bin/echo-pong
make image        # local single-platform image, docker-loaded
make scan         # Trivy scan of that image, fails on HIGH/CRITICAL
make verify        # the full one-command flow: validate -> scan -> Kind
                    # cluster + ingress-nginx -> load image (never GHCR) ->
                    # apply manifests -> wait for rollout -> curl /health,
                    # /, /ping (no/wrong/correct token) -> cleanup
```

`make verify` never pulls the production `ghcr.io/nevomenashe15-sketch/
echo-pong` image — the Kind overlay (`k8s/overlays/kind`) rewrites the
image to a locally-built tag and sets `imagePullPolicy: Never`, so the
kubelet is structurally forbidden from reaching out to any registry. See
[`docs/ARCHITECTURE.md` §10](docs/ARCHITECTURE.md#10-local-verification-workflow)
for the full explanation and what was and wasn't verified live.

### Releasing

Push a tag matching `v*` (e.g. `v0.1.0`) to trigger `release.yml`: build +
push a multi-arch image to GHCR, Trivy-scan it (blocking), promote to
semver + `latest` tags only on a clean scan, cross-compile binaries for
linux/amd64 and linux/arm64, and publish a GitHub Release with everything
attached. Ordinary commits to `main` only run `ci.yml` — no image is ever
pushed outside of a tag push.
