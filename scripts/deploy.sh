#!/usr/bin/env bash
# Apply the Firefox MCP server stack (substituting the real image ref).
#   ./scripts/deploy.sh
#   REGISTRY=other.example.com/akhil TAG=main ./scripts/deploy.sh
#
# Creates the firefox-mcp-auth Secret (one random API key) if it does not
# exist yet. The key is NEVER printed; read it back with the command that is
# shown.
set -euo pipefail
cd "$(dirname "$0")/.."

REGISTRY="${REGISTRY:-registry.rangaraj.net/akhilrangaraj}"
TAG="${TAG:-latest}"
IMG="${REGISTRY}/firefox-mcp-server:${TAG}"
NS="firefox-mcp"

echo "==> namespace"
kubectl apply -f k8s/namespace.yaml

echo "==> API key secret (firefox-mcp-auth)"
if kubectl -n "${NS}" get secret firefox-mcp-auth >/dev/null 2>&1; then
  echo "    already exists -- leaving it alone"
else
  # Fed via stdin so the key is never echoed and never appears in the process list.
  printf '%s' "$(openssl rand -hex 24)" | kubectl -n "${NS}" create secret generic firefox-mcp-auth \
    --from-file=api-keys=/dev/stdin
  echo "    created (the key itself is NOT printed)"
  echo "    read it back with:"
  echo "      kubectl -n firefox-mcp get secret firefox-mcp-auth -o jsonpath='{.data.api-keys}' | base64 -d"
fi

echo "==> statefulset (image=${IMG})"
sed "s#REPLACE_WITH_REGISTRY/firefox-mcp-server:latest#${IMG}#" k8s/statefulset.yaml | kubectl -n "${NS}" apply -f -
echo "==> service"
kubectl -n "${NS}" apply -f k8s/service.yaml
echo "==> networkpolicy"
kubectl -n "${NS}" apply -f k8s/networkpolicy.yaml

echo
echo "==> waiting for pod"
kubectl -n "${NS}" rollout status statefulset/firefox-mcp --timeout=180s
kubectl -n "${NS}" get pods,svc,pvc

echo
echo "Next:"
echo "  ./scripts/port-forward.sh"
echo "  FIREFOX_MCP_KEY=<key> ./scripts/smoke-test.sh"
