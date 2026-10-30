#!/usr/bin/env bash
# Apply the Firefox MCP server stack (substituting the real image ref).
#   REGISTRY=registry.example.com/akhil TAG=latest ./scripts/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REGISTRY="${REGISTRY:?set REGISTRY, e.g. registry.example.com/akhil}"
TAG="${TAG:-latest}"
IMG="${REGISTRY}/firefox-mcp-server:${TAG}"
NS="firefox-mcp"

echo "==> namespace"
kubectl apply -f k8s/namespace.yaml
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
echo "  ./scripts/smoke-test.sh"
