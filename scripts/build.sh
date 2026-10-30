#!/usr/bin/env bash
# Build (and optionally push) the Firefox MCP server image.
#   ./scripts/build.sh --push
#   REGISTRY=other.example.com/akhil TAG=main ./scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REGISTRY="${REGISTRY:-registry.rangaraj.net/akhilrangaraj}"
TAG="${TAG:-latest}"
IMG="${REGISTRY}/firefox-mcp-server:${TAG}"

echo "==> docker build ${IMG}"
docker build -t "${IMG}" -t "firefox-mcp-server:local" .

if [[ "${1:-}" == "--push" ]]; then
  echo "==> docker push ${IMG}"
  docker push "${IMG}"
fi

echo
echo "Done. To deploy:  REGISTRY=${REGISTRY} TAG=${TAG} ./scripts/deploy.sh"
