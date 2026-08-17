#!/usr/bin/env bash
# Smoke-tests a just-deployed release directly via the app's own Service
# (not through an ingress controller -- that path is already proven by the
# local Kind e2e flow in hack/e2e.sh). This script exists purely to answer
# one question: does the image that was just published to GHCR actually run
# and behave correctly once deployed? Used only by
# .github/workflows/release.yml's k8s-smoke-test job.
set -euo pipefail

KUBECTX="${1:?usage: release-smoke-test.sh <kube-context>}"
NAMESPACE="echo-pong"
LOCAL_PORT=18081
SECRET_FILE="k8s/overlays/release-smoke-test/.secret.local"

if [ ! -f "$SECRET_FILE" ]; then
  echo "missing $SECRET_FILE — generate it before deploying" >&2
  exit 1
fi
TOKEN="$(cat "$SECRET_FILE")"

echo "port-forwarding svc/echo-pong:80 -> localhost:${LOCAL_PORT}"
kubectl --context "$KUBECTX" -n "$NAMESPACE" port-forward svc/echo-pong "${LOCAL_PORT}:80" \
  >/tmp/echo-pong-release-smoke-portforward.log 2>&1 &
PF_PID=$!

cleanup() {
  echo "cleaning up port-forward (pid $PF_PID)"
  kill "$PF_PID" 2>/dev/null || true
  wait "$PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

ready=0
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${LOCAL_PORT}/health" || true)
  if [ "$code" = "200" ]; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "port-forward never became reachable — see /tmp/echo-pong-release-smoke-portforward.log" >&2
  cat /tmp/echo-pong-release-smoke-portforward.log >&2 || true
  exit 1
fi

fail=0
check() {
  local desc="$1" expected="$2"
  shift 2
  local code
  code=$(curl -s -o /tmp/echo-pong-release-smoke-body.json -w "%{http_code}" "$@")
  if [ "$code" = "$expected" ]; then
    echo "PASS  $desc -> $code"
  else
    echo "FAIL  $desc -> got $code, want $expected"
    echo "      body: $(cat /tmp/echo-pong-release-smoke-body.json)"
    fail=1
  fi
}

BASE="http://127.0.0.1:${LOCAL_PORT}"
check "GET /health"                 200 "$BASE/health"
check "GET /"                       200 "$BASE/"
check "GET /ping (no token)"        401 "$BASE/ping"
check "GET /ping (correct, Bearer)" 200 "$BASE/ping" -H "Authorization: Bearer ${TOKEN}"
check "GET /pong (correct, raw)"    200 "$BASE/pong" -H "Authorization: ${TOKEN}"

if [ "$fail" -ne 0 ]; then
  echo "release smoke test: FAILED"
  exit 1
fi
echo "release smoke test: all checks passed — published image is pullable and functional"
