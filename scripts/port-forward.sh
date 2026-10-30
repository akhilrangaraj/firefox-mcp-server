#!/usr/bin/env bash
# Port-forward the MCP endpoint to 127.0.0.1 (Ctrl-C to stop).
set -euo pipefail
NS="${NS:-firefox-mcp}"
PORT="${PORT:-8931}"
echo "Forwarding svc/firefox-mcp -> 127.0.0.1:${PORT}  (endpoint: /mcp)  (Ctrl-C to stop)"
kubectl -n "${NS}" port-forward svc/firefox-mcp "${PORT}:8931"
