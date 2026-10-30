#!/bin/sh
# Bridge the stdio-based Firefox MCP server over Streamable HTTP so it can be
# reached across the network (via kubectl port-forward).
#
#   supergateway (Streamable HTTP :8931/mcp)
#        |  stdio
#        v
#   firefox-devtools-mcp  (spawns + drives headless Firefox via geckodriver/BiDi)
#
# One long-lived browser per pod (stateful mode) with a persistent profile, so
# logins / cookies survive across requests and pod restarts (profile on a PVC).
set -eu

MCP_PORT="${MCP_PORT:-8931}"
MCP_HOST="${MCP_HOST:-0.0.0.0}"
FF_PATH="${FIREFOX_PATH:-/usr/local/bin/firefox}"
PROFILE="${FIREFOX_PROFILE:-/data/ff-profile}"
VIEWPORT="${VIEWPORT:-1280x720}"
TOOL_PRESET="${TOOL_PRESET:-basic}"
EXTRA_ARGS="${MCP_EXTRA_ARGS:-}"

STDIO_CMD="firefox-devtools-mcp --headless --viewport ${VIEWPORT} --firefoxPath ${FF_PATH} --profilePath ${PROFILE} --toolPreset ${TOOL_PRESET} --startUrl about:blank ${EXTRA_ARGS}"

echo "[entrypoint] supergateway -> stdio MCP over Streamable HTTP"
echo "[entrypoint]   listen : ${MCP_HOST}:${MCP_PORT}   (endpoint: /mcp)"
echo "[entrypoint]   stdio  : ${STDIO_CMD}"

exec supergateway \
  --stdio "${STDIO_CMD}" \
  --outputTransport streamableHttp \
  --stateful \
  --port "${MCP_PORT}" \
  --host "${MCP_HOST}"
