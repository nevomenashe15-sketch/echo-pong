#!/usr/bin/env bash
# Exercises the app through the Ingress controller (not a raw Service
# port-forward) to prove Ingress really is the only entry point end-to-end.
set -euo pipefail

KUBECTX="${1:?usage: e2e.sh <kube-context>}"
NAMESPACE_INGRESS="ingress-nginx"
LOCAL_PORT=18080
HOST_HEADER="echo-pong.local"
SECRET_FILE="k8s/overlays/kind/.secret.local"

if [ ! -f "$SECRET_FILE" ]; then
  echo "missing $SECRET_FILE — run 'make deploy-local' first" >&2
  exit 1
fi
TOKEN="$(cat "$SECRET_FILE")"

echo "port-forwarding svc/ingress-nginx-controller:80 -> localhost:${LOCAL_PORT}"
kubectl --context "$KUBECTX" -n "$NAMESPACE_INGRESS" port-forward svc/ingress-nginx-controller "${LOCAL_PORT}:80" \
  >/tmp/echo-pong-e2e-portforward.log 2>&1 &
PF_PID=$!

cleanup() {
  echo "cleaning up port-forward (pid $PF_PID)"
  kill "$PF_PID" 2>/dev/null || true
  wait "$PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

ready=0
for _ in $(seq 1 30); do
  if curl -s -o /dev/null "http://127.0.0.1:${LOCAL_PORT}/health" -H "Host: ${HOST_HEADER}"; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "port-forward never became reachable — see /tmp/echo-pong-e2e-portforward.log" >&2
  cat /tmp/echo-pong-e2e-portforward.log >&2 || true
  exit 1
fi

fail=0
check() {
  local desc="$1" expected="$2"
  shift 2
  local code
  code=$(curl -s -o /tmp/echo-pong-e2e-body.json -w "%{http_code}" "$@")
  if [ "$code" = "$expected" ]; then
    echo "PASS  $desc -> $code"
  else
    echo "FAIL  $desc -> got $code, want $expected"
    echo "      body: $(cat /tmp/echo-pong-e2e-body.json)"
    fail=1
  fi
}

BASE="http://127.0.0.1:${LOCAL_PORT}"
check "GET /health"                   200 "$BASE/health" -H "Host: ${HOST_HEADER}"
check "GET /"                         200 "$BASE/"       -H "Host: ${HOST_HEADER}"
check "GET /ping (no token)"          401 "$BASE/ping"   -H "Host: ${HOST_HEADER}"
check "GET /ping (wrong token)"       401 "$BASE/ping"   -H "Host: ${HOST_HEADER}" -H "Authorization: Bearer wrong-token"
check "GET /ping (correct, Bearer)"   200 "$BASE/ping"   -H "Host: ${HOST_HEADER}" -H "Authorization: Bearer ${TOKEN}"
check "GET /pong (correct, raw)"      200 "$BASE/pong"   -H "Host: ${HOST_HEADER}" -H "Authorization: ${TOKEN}"

if [ "$fail" -ne 0 ]; then
  echo "e2e: FAILED"
  exit 1
fi
echo "e2e: all checks passed"
