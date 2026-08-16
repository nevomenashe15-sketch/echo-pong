# Architecture & Design Decisions

This document explains *why* the solution in this repo is built the way it
is — deployment, scaling, security, CI/CD, multi-arch builds, versioning,
and how it maps onto AWS EKS. It's written to be defended in an interview,
not just read.

> **Note on a brief-vs-code discrepancy.** The assignment brief says the
> CLI's "secret token is passed as a command line argument." The actual
> code (`main.go`) takes it as a named flag: `--mode=cli --password=<secret>
> <ping|pong>`, not a bare positional argument. Where the brief and the code
> disagree, this solution follows the code — the brief is describing the
> app from a distance, `main.go` is the ground truth.

---

## 1. Deployment strategy

**File:** [`k8s/base/deployment.yaml`](../k8s/base/deployment.yaml)

The Deployment uses `RollingUpdate` with `maxUnavailable: 0` and
`maxSurge: 1`, `replicas: 2`, plus a `PodDisruptionBudget` with
`minAvailable: 1`. Together these are what actually make "zero-downtime"
true rather than aspirational:

- **`maxUnavailable: 0`** means the rollout is never allowed to drop below
  the current ready-replica count — Kubernetes must bring a *new* pod to
  Ready before it's allowed to remove an *old* one.
- **`maxSurge: 1`** gives the rollout room to create that extra pod above
  `replicas: 2` temporarily (so during a rollout you briefly have 3 pods,
  never fewer than 2 ready ones).
- **`replicas: 2` + PDB `minAvailable: 1`** protects against *voluntary*
  disruptions unrelated to rollouts — node drains, cluster upgrades, the
  descheduler — which `maxUnavailable`/`maxSurge` don't cover at all (those
  only govern rollout behavior).

None of this works without correct probes, because "new pod is Ready" is
exactly what gates the rollout, and the app has an unusual startup
characteristic: **it sleeps for a hardcoded 10 seconds before it starts
listening at all** (`main.go`: `time.Sleep(10 * time.Second)` right before
`http.ListenAndServe`). A naive `readinessProbe` with a short
`initialDelaySeconds` would hit connection-refused during that window,
which Kubernetes would treat as "still starting" — fine on its own — but a
naive `livenessProbe` making the same mistake would get the container
**killed and restarted before it ever got a chance to listen**, an infinite
crash loop disguised as a health check bug.

The fix is a **`startupProbe`**:

```yaml
startupProbe:
  httpGet: {path: /health, port: http}
  initialDelaySeconds: 5
  periodSeconds: 3
  failureThreshold: 10   # 5s + 10*3s = up to 35s of headroom
readinessProbe: {...}     # only evaluated after startupProbe succeeds
livenessProbe:  {...}     # only evaluated after startupProbe succeeds
```

While a `startupProbe` is defined, `readinessProbe` and `livenessProbe` are
**not evaluated at all** until it succeeds once. So the 10s sleep is fully
absorbed by the startup window (5s initial delay + up to 30s of retries —
comfortable headroom past the fixed 10s, without being so long that a
genuinely crashed container takes forever to be noticed), and it's
*structurally impossible* for the sleep to be mistaken for a liveness
failure. Once startup succeeds, `/health` has no dependencies to check, so
short readiness/liveness periods (5s / 10s) are safe and give fast signal
if a pod genuinely stops responding.

**Why RollingUpdate and not Recreate/Blue-Green/Canary:** `Recreate` tears
down all pods before creating new ones — by definition not zero-downtime.
Blue-Green and Canary are strictly better for risk control (instant
rollback, gradual traffic shift) but need extra infrastructure this app
doesn't have yet (a service mesh or a smarter ingress for traffic
splitting, an external deployment tool like Argo Rollouts/Flagger).
RollingUpdate with `maxUnavailable: 0` is the standard, dependency-free way
to get zero-downtime *rollouts* specifically; if this service needed
progressive canary rollout with automated rollback on error-rate, that's
the documented next step, not something faked with plain Kubernetes
primitives here.

---

## 2. Scaling strategy

**File:** [`k8s/base/hpa.yaml`](../k8s/base/hpa.yaml)

`HorizontalPodAutoscaler` (`autoscaling/v2`), `minReplicas: 2`,
`maxReplicas: 6`, target 70% average CPU utilization.

- **`minReplicas: 2`** matches the Deployment's own replica count, so the
  HPA can never scale below what the PDB/RollingUpdate math above already
  assumes. Scaling to 1 would silently break the zero-downtime guarantee.
- **`maxReplicas: 6`** is a deliberately small ceiling. This is a
  stateless, effectively free-to-compute ping/pong handler (`resources.
  requests`: 50m CPU / 32Mi memory) — it isn't going to need 50 replicas
  under any traffic level this assignment implies, and an unbounded ceiling
  on a take-home assignment cluster is just a foot-gun.
- **CPU, not custom metrics:** CPU utilization is the right metric *for
  this app* because it does no I/O-bound waiting (no downstream calls, no
  DB) — CPU usage tracks request volume reasonably well. A service with
  significant I/O wait (calls to a slow downstream, DB queries) would scale
  on CPU too late, since a thread pool full of *waiting* requests doesn't
  show up as CPU load — that's when you'd add a custom/external metric
  (requests-per-second via Prometheus Adapter, or a KEDA scaler on queue
  depth). Documented as the natural next step if this service ever calls
  out to something.
- **`behavior.scaleDown.stabilizationWindowSeconds: 300`**: waits 5 minutes
  of sustained low usage before removing a replica, so a brief dip doesn't
  cause scale-down/scale-up flapping. `scaleUp` has no stabilization delay
  (`0`) — under real load you want extra capacity immediately, not after a
  cooldown.

Testing this live requires the `metrics-server` add-on (not present in Kind
by default) — see [§9](#9-what-i-did-and-didnt-verify-live).

---

## 3. Security measures

Every item maps directly to something in the assignment's security
checklist and to a specific file/line:

| Requirement | Where | How |
|---|---|---|
| No containers running as root | [`Dockerfile`](../Dockerfile), [`deployment.yaml`](../k8s/base/deployment.yaml) | Distroless `nonroot` base image (UID 65532 baked in, no root user exists in the image at all — not even unused); `securityContext.runAsNonRoot: true` + `runAsUser: 65532` enforced again at the pod/container level; namespace-wide Pod Security Admission `enforce: restricted` ([`namespace.yaml`](../k8s/base/namespace.yaml)) rejects any pod that doesn't comply, so it's not just a convention |
| Filesystem isolation | `deployment.yaml` | `readOnlyRootFilesystem: true`. The app never writes to disk (confirmed by reading `main.go` — it only reads the mounted secret file and writes HTTP responses/stdout), so this needed no writable `emptyDir` exceptions |
| Minimal attack surface | `Dockerfile` | Multi-stage build; final image is `gcr.io/distroless/static-debian12:nonroot` — no shell, no package manager, no libc (matches `CGO_ENABLED=0`), pinned by digest (not just tag) so the base image can't silently change under us |
| No added Linux capabilities | `deployment.yaml` | `capabilities.drop: [ALL]`, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault` |
| Secret handling | `deployment.yaml`, [`secret.example.yaml`](../k8s/secret.example.yaml) | Mounted as a **read-only file** via a Secret volume (`defaultMode: 0440`) at the exact path `SECRET_FILE_PATH` already expects — never an env var (env vars leak into `kubectl describe`, process listings, and crash dumps far more easily than a mounted file) |
| No secrets in codebase | `.gitignore`, `k8s/secret.example.yaml` | Real secret material is never committed. The example Secret manifest is clearly marked as a template and deliberately excluded from every `kustomization.yaml`, so `kubectl apply -k` can never apply it by accident. Local Kind testing generates a throwaway token into a gitignored `.secret.local` file consumed by a Kustomize `secretGenerator` — see [§8](#8-local-verification-workflow) |
| No direct internet access (ingress/proxy only) | [`networkpolicy.yaml`](../k8s/base/networkpolicy.yaml), [`ingress.yaml`](../k8s/base/ingress.yaml) | `NetworkPolicy` default-denies all ingress/egress for the app's pods, then allows ingress **only** from the namespace running the ingress controller, on port 8080. Egress is fully denied — verified from `main.go` that the app makes zero outbound calls, so there's nothing to allow, not even DNS |
| Image scanning gate | `release.yml` | Trivy scans the exact pushed image digest (both `linux/amd64` and `linux/arm64`) and **fails the job** on any HIGH/CRITICAL finding — see [§4](#4-cicd-pipeline) for why this is a real gate and not just a report |

One nuance worth being upfront about in an interview: **whether
`NetworkPolicy` is even enforced depends entirely on the cluster's CNI.**
Kind's default CNI (`kindnet`) does not enforce `NetworkPolicy` at all —
the manifest applies and validates successfully, but nothing is actually
blocked in local testing. On EKS this matters concretely: the default AWS
VPC CNI didn't support `NetworkPolicy` for a long time and needs either the
VPC CNI's native policy enforcement mode enabled or a policy-capable CNI
add-on (Calico, Cilium) layered in. This is called out explicitly rather
than silently assumed — see [§6](#6-cloud-deployment-on-aws-eks).

---

## 4. CI/CD pipeline

**Files:** [`.github/workflows/ci.yml`](../.github/workflows/ci.yml),
[`go-checks.yml`](../.github/workflows/go-checks.yml),
[`release.yml`](../.github/workflows/release.yml)

### `ci.yml` — every push to `main` and every PR

Seven independent, parallel jobs, each a real gate (no
`continue-on-error`, no `|| true`):

1. **`go-checks`** (calls the reusable `go-checks.yml`) — `gofmt` check,
   `go vet`, `golangci-lint`, `go test -race`.
2. **`docker-lint`** — hadolint against the Dockerfile.
3. **`workflow-lint`** — actionlint against the workflow files themselves.
4. **`yaml-lint`** — yamllint against k8s manifests and workflows.
5. **`k8s-validate`** — renders `k8s/base` and `k8s/overlays/kind` via
   `kubectl kustomize`, validates both with `kubeconform -strict` against
   the Kubernetes 1.31 schema.
6. **`no-committed-secrets`** — greps tracked files for anything that looks
   like a real Secret value outside the explicitly-marked example.
7. **`docker-build-check`** — `docker buildx build` for
   `linux/amd64,linux/arm64` with `push: false`, to catch a broken
   Dockerfile/build before it ever reaches the release pipeline.

Every one of these jobs runs the *exact same* underlying command a
developer runs locally (`make fmt`, `make lint`, `make test`, `make
docker-lint`, ...) — see the [Makefile](../Makefile). CI is a trigger and
environment setup around the Makefile, not a second implementation of the
checks, so local and CI can't drift apart.

### `release.yml` — only on tag push (`v*`)

**Why gate on tags, not every commit to `main`:** publishing an image and
cutting a GitHub Release are *release* actions with external consequences
(other teams/clusters may pull that tag) — they shouldn't happen on every
merge to `main`, only on an explicit, reviewable decision to ship a
version. A git tag is that explicit decision.

```
go-checks (reusable — same gate as CI)
        │
        ▼
build-and-scan ── build multi-arch image, push under a provisional
        │          sha-<commit>-only tag (never latest, never semver) ──►
        │          Trivy scans that exact pushed digest, amd64 AND arm64,
        │          fails the job on any HIGH/CRITICAL finding
        │
        ▼ (only reached if the scan passed)
   promote ─────── docker buildx imagetools create: attaches the real
        │          semver tags + `latest` to the SAME digest — no rebuild
        │
        ▼
github-release ── binaries (built in parallel, needs only go-checks)
                   + the promoted image are published together
```

The scan-then-promote split is the actual gating mechanism, and it's worth
being able to explain precisely why: if the workflow scanned the image
*after* it already had its `latest`/semver tags, a failing scan would only
be a report that arrives too late — the bad image is already the one
everyone pulls. Here, `latest` and the semver tag **do not exist** until
`promote` runs, and `promote` only runs if `build-and-scan` (Trivy included)
exited zero. A failed scan leaves only a `sha-<commit>` tag behind — not
"released" by this repo's own definition of what a release tag means — and
that's exactly the kind of unpromoted artifact the retention policy in
[§9](#9-image-lifecycle-management) is designed to clean up automatically.

**Auth:** `docker/login-action` uses `secrets.GITHUB_TOKEN` (scoped by the
job's own `permissions: packages: write`), not a personal access token.
Nothing in any workflow file is a committed credential.

---

## 5. Multi-architecture build approach

**File:** [`Dockerfile`](../Dockerfile)

```dockerfile
FROM --platform=$BUILDPLATFORM golang:1.24-bookworm@sha256:... AS build
...
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build ...
```

The build stage runs on the **build host's native architecture**
(`--platform=$BUILDPLATFORM`) regardless of which architecture the final
image targets. Go's own cross-compiler (`GOOS`/`GOARCH`) then produces the
target-architecture binary directly — so **QEMU emulation is never used for
the compute-heavy compilation step**. QEMU only comes into play (via
`docker/setup-qemu-action` in CI) for the trivial final-stage `COPY` when
the runner's native architecture differs from a requested target. This is
the standard, efficient buildx pattern for compiled languages: emulate the
cheap step, cross-compile the expensive one.

`buildx` then assembles both single-arch images into a single **OCI
manifest list** (what `docker/build-push-action` pushes) — one tag,
multiple platforms; the client's own architecture picks the right one
automatically on pull.

**GitHub-hosted runners are amd64-only**, so both `ci.yml`'s build-check
and `release.yml`'s real build rely on QEMU to even attempt the arm64
half. A native arm64 runner (GitHub now offers these, or self-hosted
Graviton) would build the arm64 half faster and without emulation risk —
documented as a reasonable upgrade if arm64 build time or QEMU edge cases
ever become a problem, not something this assignment's scale needs yet.

---

## 6. Versioning & tagging strategy

- **Images:** every tag pushed to GHCR is immutable in the sense that
  matters — `sha-<commit>` never changes meaning, and semver tags
  (`v1.2.3`, `1.2`, `1`) are only ever attached once, to the digest that
  passed the scan (see §4). `latest` is **not** the only tag ever produced
  — the assignment explicitly calls out "no `:latest`-only releases," and
  every release always gets its full semver tag set alongside `latest`.
  `latest` is a convenience pointer for "current stable," never the
  authoritative reference — production Kubernetes manifests should pin an
  exact tag or digest, not `latest` (see the placeholder tag discipline in
  `k8s/base/deployment.yaml`).
- **Binaries:** filenames embed the tag directly —
  `echo-pong-v1.2.3-linux-amd64` / `-arm64` — plus a `.sha256` checksum
  file per binary, uploaded to the GitHub Release.
- **Git tags → semver:** annotated tags matching `v*` (validated informally
  by `docker/metadata-action`'s semver parser, which only produces tags for
  well-formed `vMAJOR.MINOR.PATCH` refs). A malformed tag simply produces
  no semver Docker tags — a cheap, built-in guard against accidental
  garbage releases.
- **Kubernetes manifests never hardcode a real tag.** `k8s/base/
  deployment.yaml` ships a deliberately-named placeholder
  (`0.0.0-unset`) that's meant to be overridden via Kustomize's `images:`
  transformer at deploy time (exactly what `k8s/overlays/kind` does for
  local testing, and what a real CD step would do for a target
  environment) — so the base manifests stay honest about which repo the
  image comes from without ever being deployable as-is by accident.

---

## 7. Cloud deployment on AWS EKS

Mapping each piece of this local solution to its EKS equivalent:

| Local / this repo | AWS EKS equivalent | Why the change |
|---|---|---|
| Kind cluster, single node | **EKS managed node groups** for baseline/system capacity + **Karpenter** for dynamic application capacity | Karpenter provisions right-sized nodes (including Graviton/arm64, matching this Deployment's soft arm64 preference) directly in response to unschedulable pods — faster and more bin-packing-efficient than Cluster Autoscaler's ASG-based model. A small managed node group still exists so the cluster can bootstrap itself (CoreDNS, controllers) without depending on Karpenter being healthy yet |
| Fargate vs. managed nodes | **Managed node groups (+ Karpenter)**, not Fargate, for this workload | Fargate is attractive for its per-pod isolation and zero node management, but it doesn't support `DaemonSet`s, has slower cold starts (worse for a service already sensitive to startup timing, per §1), and loses the arm64/Graviton cost story this Deployment is already designed around. Fargate remains a reasonable choice for spiky, low-and-simple workloads that don't need any of that — just not this one |
| k8s Secret (file-mounted) | **IRSA / EKS Pod Identity** + **External Secrets Operator**, syncing from **AWS Secrets Manager**, still mounted as a file | The mechanism the app expects (`SECRET_FILE_PATH` pointing at a mounted file) doesn't change at all — ESO's whole design point is to keep syncing *into* a normal k8s Secret so nothing downstream needs to change. What changes is where the value's source of truth lives (Secrets Manager, with rotation/audit/IAM-scoped access) instead of a manually-created cluster Secret, and the pod authenticates to AWS via IRSA/Pod Identity — a scoped IAM role bound to the ServiceAccount — instead of any mounted static AWS credential |
| `ingress-nginx` (Kind) | **AWS Load Balancer Controller** reconciling the same `Ingress` object into an internet-facing **ALB** (IP target mode, routing straight to pod IPs, not NodePort) | The `Ingress` YAML itself barely changes — swap `ingressClassName` and add the controller's annotations (health-check path `/health`, HTTPS listener/redirect, target-type). The controller is what actually creates/updates AWS load balancer resources; the Ingress object is declarative intent, not a runtime proxy |
| `NetworkPolicy` (unenforced by Kind's CNI) | VPC CNI's native `NetworkPolicy` enforcement (or Calico/Cilium as an add-on) | Called out explicitly rather than assumed: on EKS, whether this repo's `NetworkPolicy` manifest does anything at all depends on which policy engine is actually installed — it must be verified, not assumed, for whichever cluster this actually deploys to |
| GHCR | **Amazon ECR** (see §8 for the fast-global-pull angle specifically) | Same immutable-tag, scan-on-push, least-privilege-policy story as GHCR; ECR is the natural registry once workloads run in AWS, mainly for the IAM-native pull auth and VPC-local pull path (§8) |
| GitHub OIDC → GITHUB_TOKEN | **GitHub OIDC → a scoped AWS IAM role** (`aws-actions/configure-aws-credentials`, no static AWS keys) | Same "no long-lived credential" principle already used for GHCR, extended to AWS: the workflow assumes a narrowly-scoped IAM role via OIDC federation, time-limited to the job's run |
| Cluster autoscaling: N/A (Kind is single-node, fixed) | **Karpenter** (preferred) or **Cluster Autoscaler** (ASG-based, if Karpenter isn't adopted) | Karpenter is the more modern, faster-provisioning, better-bin-packing option and was designed to replace Cluster Autoscaler for exactly this kind of stateless, horizontally-scaled service |

---

## 8. Fast global image pulls (AWS-specific)

For teams pulling this image from different regions/continents, three AWS
mechanisms address different parts of the latency/cost problem:

1. **ECR cross-region replication** (or an ECR **pull-through cache** in
   front of GHCR) — puts a copy of the image in the region closest to each
   team, so a pull in `ap-southeast-1` doesn't cross an ocean to
   `us-east-1` on every single pull. Pull-through cache is the lighter-touch
   option if the image should keep living primarily in GHCR; full
   replication is better once ECR becomes the actual source of truth.
2. **VPC endpoints for ECR** (`ecr.api` and `ecr.dkr` interface endpoints,
   **plus the S3 gateway endpoint** — ECR image layers are actually served
   through S3, so the interface endpoints alone aren't sufficient) — keeps
   pulls entirely inside the VPC instead of routing through a NAT Gateway,
   which is both a latency win and a direct cost win (NAT Gateway
   per-GB processing charges add up fast for image pulls at any real
   scale).
3. **CloudFront in front of the binary releases** (the GitHub Release
   assets, or a mirrored S3 bucket) — this is the piece that matters
   specifically for *binary* downloads rather than container pulls, since
   GitHub Releases themselves aren't globally edge-cached the way an S3 +
   CloudFront distribution would be. Not needed for the container image
   path at all — that's what ECR replication/VPC endpoints already solve.

Container pulls and raw binary downloads are genuinely different problems
here — worth stating plainly rather than reaching for one tool that only
half-fits both.

---

## 9. Image lifecycle management

Retention policy, and how it ties back to the versioning scheme in §6:

| Tag pattern | Retention |
|---|---|
| Semver release tags (`v1.2.3`, `1.2`, `1`) | **Keep forever** — these are the only tags meant to be reproducible/citable long-term; deleting one silently breaks anyone pinned to it |
| `latest` | Kept, always repointed to the newest release — not itself a retention concern |
| `sha-<commit>` (provisional/build tags — see §4) | Keep the **last N** (e.g. 20) regardless of age, **delete the rest after 14 days**. A `sha-` tag that never got promoted (failed its Trivy gate, or was superseded) has no reason to be kept indefinitely |
| Untagged manifests (orphaned after a `imagetools create` retag, or superseded multi-arch sub-manifests) | Delete after **7 days** — GHCR/ECR lifecycle policies can target "untagged" specifically |
| PR-build images (if ever added — not currently produced, since `ci.yml`'s `docker-build-check` job never pushes) | Would get the shortest retention of all (e.g. 3 days) if introduced later |

On GHCR specifically, this is expressed as a `container.yml` package-cleanup
workflow (or the repo's package retention settings) keyed on tag pattern and
age, mirroring exactly the tag scheme in §6 — nothing here is
retention-policy-driven-by-guesswork; it's retention driven by "what does
this tag pattern *mean*," which is precisely why §6's tagging discipline
(sha-tags are provisional, semver tags are permanent) matters beyond just
being tidy. On ECR, the equivalent is a native **lifecycle policy** with
rules ordered by `tagStatus` (`tagged` matching `sha-*` vs. `untagged`) and
`countType: sinceImagePushed`.

Critically, **no automated cleanup should run blind** — before deleting any
digest, it must be diffed against what's actually currently deployed
(every environment's live image reference), never just against tag
age/count in isolation. A digest that's 30 days old but is still what
production is running is not safe to delete just because it "looks stale"
by a naive policy.

---

## 10. Local verification workflow

**Files:** [`Makefile`](../Makefile), [`hack/kind-config.yaml`](../hack/kind-config.yaml), [`hack/e2e.sh`](../hack/e2e.sh)

One command, `make verify`, runs the entire local pipeline end-to-end:
static validation → build → Trivy scan → Kind cluster → ingress-nginx →
image load (never a registry pull) → manifest apply → rollout wait →
port-forward through the ingress → `/health`, `/`, `/ping` (no/wrong/correct
token) → cleanup. See the [README](../README.md#local-development) for the
full command reference and the exact output from a real run.

**How the local run can never accidentally touch GHCR:** `k8s/overlays/
kind/kustomization.yaml` rewrites the image reference to a locally-tagged
name (`ping-pong-game:kind-local`) that is never pushed anywhere, and
patches `imagePullPolicy: Never` — even if the image name/tag were
somehow wrong, the kubelet is *forbidden* from pulling over the network at
all; it must already be present on the Kind node via `kind load
docker-image`. The production image reference in `k8s/base/deployment.yaml`
is never touched by this overlay.

### What I did and didn't verify live

Being direct about the boundary of what was actually exercised end-to-end
locally, versus what's correct by inspection/schema-validation but wasn't
run against a live cluster:

- **Verified live:** image build, Trivy scan, Kind cluster + ingress-nginx,
  manifest apply, rollout, and all six HTTP checks (`/health`, `/`, `/ping`
  × no/wrong/correct token) through the real Ingress path.
- **Validated but not live-enforced:** `NetworkPolicy` — Kind's default CNI
  doesn't enforce it (§3), so this was schema-validated and applied
  successfully, not proven to actually block traffic. Proving real
  enforcement would mean installing Calico into Kind (or testing on
  EKS with a policy-capable CNI).
- **Not exercised locally:** the HPA's live scaling behavior, since Kind
  doesn't ship `metrics-server` by default — the manifest is schema-valid
  and the target/threshold reasoning is in §2, but no load test was run
  against it in this pass.
