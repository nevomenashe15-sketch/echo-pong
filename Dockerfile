# syntax=docker/dockerfile:1

# --- build stage -------------------------------------------------------
# Runs on the build host's *native* architecture (--platform=$BUILDPLATFORM)
# even when the target image is a different arch. Go's own cross-compiler
# (GOOS/GOARCH) produces the target binary directly, so buildx never needs
# QEMU emulation for this compute-heavy step — only the tiny final-stage
# COPY runs under emulation for non-native targets.
#
# Toolchain intentionally newer than go.mod's `go 1.24` directive: Go only
# backports security fixes to the latest two minor releases, and 1.24 has
# aged out of that window (confirmed by Trivy flagging stdlib CVEs in this
# exact binary that are fixed in 1.25.13/1.26.6 but have no 1.24 fix at
# all). A newer toolchain compiling a `go 1.24`-declared module is fully
# supported and doesn't change source-level behavior — it only ships a
# patched standard library. go.mod's directive is left at 1.24 to match
# the assignment's stated requirement; only the build image is bumped.
FROM --platform=$BUILDPLATFORM golang:1.26-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 AS build

ARG TARGETOS
ARG TARGETARCH

WORKDIR /src

COPY go.mod ./
RUN go mod download

COPY main.go ./

RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/ping-pong-game .

# --- final stage ---------------------------------------------------------
# distroless "static:nonroot" ships no shell, no package manager, and no
# libc (matches CGO_ENABLED=0) — nothing an attacker can pivot to even with
# code execution. It also already runs as a non-root numeric UID (65532);
# it is set again explicitly below so the intent is visible in this file
# rather than only implied by the base image.
FROM gcr.io/distroless/static-debian12:nonroot@sha256:1b7b9f0f0e0a1d2155f531db587cc48ec26aaf97ab64364225f5bf18a054e66a AS final

WORKDIR /
COPY --from=build /out/ping-pong-game /ping-pong-game

USER 65532:65532

# Documentation only — the actual port is controlled by $PORT at runtime
# and enforced by the Kubernetes Service/containerPort, not by this image.
EXPOSE 8080

ENTRYPOINT ["/ping-pong-game"]
