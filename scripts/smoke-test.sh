#!/usr/bin/env bash
# Smoke-test a running (port-forwarded) Firefox MCP server over
# MCP/Streamable-HTTP.
#
#   BASE             base URL, default http://127.0.0.1:8931
#   FIREFOX_MCP_KEY  the API key (required)
#   SMOKE_URL        page to navigate to, default https://example.com
#                    (point it at a local page, e.g. a python http.server,
#                    to test without internet)
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:8931}"
URL="${SMOKE_URL:-https://example.com}"

if [ -z "${FIREFOX_MCP_KEY:-}" ]; then
  echo "error: FIREFOX_MCP_KEY is not set (the MCP API key)." >&2
  exit 1
fi

HDRS="$(mktemp)"
trap 'rm -f "${HDRS}"' EXIT

# Session id from the most recent response (empty before initialize).
SID=""

mcp_post() {
  # mcp_post <json-rpc-payload> -- POST with the API key (and the session id,
  # once known). Body goes to stdout; response headers are captured in $HDRS.
  local args=(-sS -m 90 -D "${HDRS}" -X POST "${BASE}/mcp"
    -H "Authorization: Bearer ${FIREFOX_MCP_KEY}"
    -H 'Content-Type: application/json'
    -H 'Accept: application/json, text/event-stream')
  if [ -n "${SID}" ]; then args+=(-H "mcp-session-id: ${SID}"); fi
  curl "${args[@]}" -d "$1"
}

sse_data() {
  # Return the raw JSON-RPC payloads from an SSE or plain-JSON response body.
  local body="$1" stripped
  stripped="$(printf '%s\n' "${body}" | sed -n 's/^data:[[:space:]]*//p')"
  if [ -n "${stripped}" ]; then
    printf '%s\n' "${stripped}"
  else
    printf '%s\n' "${body}"
  fi
}

session_id() {
  tr -d '\r' < "${HDRS}" | awk 'tolower($1) == "mcp-session-id:" {print $2; exit}'
}

echo "== 1. unauthenticated request must be rejected (401) =="
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 20 -X POST "${BASE}/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}')"
if [ "${CODE}" != "401" ]; then
  echo "error: expected HTTP 401 without an API key, got ${CODE}" >&2
  exit 1
fi
echo "ok: no key -> ${CODE}"

echo "== 2. GET /healthz =="
HZ="$(curl -fsS -m 20 "${BASE}/healthz")"
echo "ok: /healthz -> ${HZ}"

echo "== 3. initialize =="
BODY="$(mcp_post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}')"
printf '%.300s\n' "${BODY}"
SID="$(session_id)"
echo "session-id: ${SID:-<none>}"
if [ -z "${SID}" ]; then
  echo "error: no mcp-session-id header in the initialize response" >&2
  exit 1
fi

echo "== 4. notifications/initialized =="
curl -sS -m 30 -o /dev/null -w 'ok: HTTP %{http_code}\n' -X POST "${BASE}/mcp" \
  -H "Authorization: Bearer ${FIREFOX_MCP_KEY}" \
  -H "mcp-session-id: ${SID}" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

echo "== 5. tools/list (names) =="
TOOLS_BODY="$(mcp_post '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
NAMES="$(sse_data "${TOOLS_BODY}" | jq -r '.result.tools[].name' 2>/dev/null | sort)"
if [ -z "${NAMES}" ]; then
  echo "error: tools/list returned no tools; raw body:" >&2
  printf '%.800s\n' "${TOOLS_BODY}" >&2
  exit 1
fi
printf '%s\n' "${NAMES}" | tr '\n' ' '
echo
echo "tool count: $(printf '%s\n' "${NAMES}" | wc -l)"

echo "== 6. navigate_page -> ${URL} =="
BODY="$(mcp_post "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"navigate_page\",\"arguments\":{\"url\":\"${URL}\"}}}")"
printf '%.500s\n' "${BODY}"

echo "== 7. page text =="
TEXT_TOOL=""
for CANDIDATE in get_page_text take_snapshot; do
  if printf '%s\n' "${NAMES}" | grep -qx "${CANDIDATE}"; then TEXT_TOOL="${CANDIDATE}"; break; fi
done
if [ -z "${TEXT_TOOL}" ]; then
  echo "error: no page-text tool (get_page_text) in the tool list" >&2
  exit 1
fi
BODY="$(mcp_post "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"${TEXT_TOOL}\",\"arguments\":{}}}")"
printf '%.500s\n' "${BODY}"

echo "== 8. DELETE session =="
DEL_CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 30 -X DELETE "${BASE}/mcp" \
  -H "Authorization: Bearer ${FIREFOX_MCP_KEY}" \
  -H "mcp-session-id: ${SID}")"
echo "ok: DELETE -> HTTP ${DEL_CODE}"

echo "SMOKE TEST PASSED"
