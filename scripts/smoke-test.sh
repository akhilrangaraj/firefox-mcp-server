#!/usr/bin/env bash
# Smoke-test a running (port-forwarded) Firefox MCP server over MCP/Streamable-HTTP.
set -euo pipefail
BASE="${BASE:-http://127.0.0.1:8931}"

echo "== MCP initialize =="
curl -s -m 20 -D /tmp/mcp_hdr -X POST "${BASE}/mcp" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  | head -c 300
echo; echo

SID="$(grep -i '^mcp-session-id:' /tmp/mcp_hdr 2>/dev/null | awk '{print $2}' | tr -d '\r' || true)"
echo "session-id: ${SID:-<stateless / none>}"

echo "== tools/list (names) =="
curl -s -m 20 -X POST "${BASE}/mcp" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "mcp-session-id: ${SID}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | grep -oE '"name":"[a-z_]+" ' | sed 's/"name":"//;s/" //g' | sort | head -60

echo
echo "== try: navigate to example.com + page text =="
TOOL_CALL='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"navigate_page","arguments":{"url":"https://example.com"}}}'
curl -s -m 60 -X POST "${BASE}/mcp" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "mcp-session-id: ${SID}" -d "${TOOL_CALL}" | head -c 600
echo
