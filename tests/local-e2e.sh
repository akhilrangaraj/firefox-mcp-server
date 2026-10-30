#!/usr/bin/env bash
# Local end-to-end test: runs the REAL entrypoint.sh -> supergateway ->
# @mozilla/firefox-devtools-mcp -> a real headless Firefox, with no docker and
# no cluster. It also drives the smoke test (initialize / tools/list /
# navigate / page text / session DELETE) against a local web page, so no
# internet is needed for the navigation.
#
#   bash tests/local-e2e.sh
#
# What it asserts:
#   * the entrypoint refuses to start (non-zero) when the API key file is
#     missing and MCP_AUTH_DISABLED is not set;
#   * a stale profile `lock` / `.parentlock` does NOT prevent launch;
#   * /healthz answers; unauthenticated requests get 401; a full MCP session
#     works end-to-end (page text from a local server matches a unique marker).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# --- Persistent cache (reused across runs) --------------------------------
CACHE="${E2E_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/firefox-mcp-e2e}"
mkdir -p "$CACHE"

# --- Per-run temp dirs (all removed on exit) ------------------------------
WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/ffmcp-e2e.XXXXXX")"
TMP="$WORKROOT/lib"        # npm --prefix for the pinned packages
PROFILE="$WORKROOT/profile"
HOMEDIR="$WORKROOT/home"
KEYFILE="$WORKROOT/api-keys"
LOGS="$WORKROOT/logs"
WEBROOT="$WORKROOT/web"
mkdir -p "$TMP" "$PROFILE" "$HOMEDIR/.firefox-devtools-mcp" "$LOGS" "$WEBROOT"

SERVER_PID=""
HTTPD_PID=""
cleanup() {
  local i
  if [ -n "$SERVER_PID" ]; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.5
    done
    kill -KILL "$SERVER_PID" 2>/dev/null || true
  fi
  [ -n "$HTTPD_PID" ] && kill "$HTTPD_PID" 2>/dev/null || true
  # Belt and braces: end anything still bound to our unique profile dir.
  pkill -f "$PROFILE" 2>/dev/null || true
  rm -rf "$WORKROOT"
}
trap cleanup EXIT

free_port() {
  python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}

echo "repo:      $REPO"
echo "cache:     $CACHE"
echo "workroot:  $WORKROOT"

# --- 1. Install the pinned packages into a temp dir -----------------------
echo
echo "== [1/7] install pinned packages =="
npm install --no-save --no-audit --no-fund --prefix "$TMP" \
  @mozilla/firefox-devtools-mcp@0.10.7 supergateway@4.2.1 \
  >"$LOGS/npm-install.log" 2>&1 || { cat "$LOGS/npm-install.log" >&2; exit 1; }
[ -x "$TMP/node_modules/.bin/supergateway" ] || { echo "error: supergateway binary missing" >&2; exit 1; }
[ -x "$TMP/node_modules/.bin/firefox-devtools-mcp" ] || { echo "error: firefox-devtools-mcp binary missing" >&2; exit 1; }
echo "ok: pinned packages installed"

# --- 2. Get a real Firefox (reused across runs) ---------------------------
echo
echo "== [2/7] firefox =="
FF_LAST="$(npx --yes @puppeteer/browsers install firefox@stable --path "$CACHE" \
  2>"$LOGS/ff-install.log" | awk 'NF { line = $0 } END { print line }')"
FF_BIN="${FF_LAST##* }"
[ -x "$FF_BIN" ] || { echo "error: firefox binary not found: ${FF_BIN}" >&2; cat "$LOGS/ff-install.log" >&2; exit 1; }
echo "ok: firefox: $FF_BIN"

# --- 3. Resolve geckodriver (cached; put on PATH so no download at runtime)
echo
echo "== [3/7] geckodriver =="
GECKO_DIR="$CACHE/geckodriver"
# No version argument: the package resolves the latest geckodriver release
# (same as the MCP server's own fallback) and reuses the cached binary.
# The package also logs INFO lines to stdout, so take the last path-looking line.
GECKO_BIN="$(cd "$TMP" && node --input-type=module -e \
  'const { download } = await import("geckodriver");
   console.log(await download(undefined, process.argv[1]));' "$GECKO_DIR" \
  | awk '$0 ~ /^\// { line = $0 } END { print line }')"
[ -x "$GECKO_BIN" ] || { echo "error: geckodriver not found at ${GECKO_BIN}" >&2; exit 1; }
echo "ok: geckodriver: $GECKO_BIN"
PATH_PREPEND="$GECKO_DIR:$TMP/node_modules/.bin"

# --- 4. Entry point must FAIL without a key file ---------------------------
echo
echo "== [4/7] entrypoint refuses to start without a key file =="
if env -u MCP_AUTH_DISABLED \
     MCP_API_KEY_FILE="$WORKROOT/no-such-key-file" \
     HOME="$HOMEDIR" \
     PATH="$PATH_PREPEND:$PATH" \
     bash entrypoint.sh >"$LOGS/authfail.log" 2>&1; then
  echo "error: entrypoint should have exited non-zero without a key file" >&2
  cat "$LOGS/authfail.log" >&2
  exit 1
fi
echo "ok: exited non-zero as required"
grep -qi "API key file" "$LOGS/authfail.log" && echo "ok: printed a clear error message"

# --- 5. Local web page + server (no internet needed for navigation) -------
echo
echo "== [5/7] local web server =="
MARKER="FIREFOX-MCP-E2E-MARKER-$$"
cat > "$WEBROOT/index.html" <<EOF
<!doctype html><html><head><title>e2e</title></head>
<body>${MARKER} local-e2e page hello</body></html>
EOF
WEBPORT="$(free_port)"
( cd "$WEBROOT" && exec python3 -m http.server "$WEBPORT" --bind 127.0.0.1 ) \
  >"$LOGS/httpd.log" 2>&1 &
HTTPD_PID=$!
for i in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:${WEBPORT}/index.html" >/dev/null 2>&1 && break
  sleep 0.2
done
curl -fsS "http://127.0.0.1:${WEBPORT}/index.html" >/dev/null
echo "ok: local web server on 127.0.0.1:${WEBPORT}"

# --- 6. Start the real entrypoint (stale lock present on purpose) ---------
echo
echo "== [6/7] start entrypoint (with a stale profile lock) =="
KEY="e2e-$(openssl rand -hex 16)"
printf '%s\n' "$KEY" > "$KEYFILE"
chmod 600 "$KEYFILE"
# Simulate a crash left a lock behind; the entrypoint must remove it and start.
# On Linux Firefox's `lock` is a dangling symlink to "<ip>:+<pid>", and it lives
# in the firefox_devtools_mcp_profile/ subdir that the MCP server actually runs
# Firefox in (not in FIREFOX_PROFILE itself).
LOCKDIR="$PROFILE/firefox_devtools_mcp_profile"
mkdir -p "$LOCKDIR"
ln -s "10.255.255.1:+4242" "$LOCKDIR/lock"
echo "stale" > "$LOCKDIR/.parentlock"
echo "note: planted stale ${LOCKDIR}/lock and .parentlock"

MCP_PORT="$(free_port)"
env MCP_HOST=127.0.0.1 \
    MCP_PORT="$MCP_PORT" \
    FIREFOX_PATH="$FF_BIN" \
    FIREFOX_PROFILE="$PROFILE" \
    MCP_API_KEY_FILE="$KEYFILE" \
    MCP_SESSION_TIMEOUT_MS=120000 \
    HOME="$HOMEDIR" \
    PATH="$PATH_PREPEND:$PATH" \
  bash entrypoint.sh >"$LOGS/entrypoint.log" 2>&1 &
SERVER_PID=$!
echo "server pid: $SERVER_PID   base: http://127.0.0.1:${MCP_PORT}"

echo "waiting for /healthz ..."
READY=""
for i in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${MCP_PORT}/healthz" >/dev/null 2>&1; then READY=1; break; fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "error: entrypoint exited during startup; log:" >&2
    cat "$LOGS/entrypoint.log" >&2
    exit 1
  fi
  sleep 0.5
done
[ -n "$READY" ] || { echo "error: /healthz never became ready; log:" >&2; cat "$LOGS/entrypoint.log" >&2; exit 1; }
echo "ok: /healthz is up (stale lock did not block launch)"
# Firefox is launched lazily on the first browser tool call, so anything still
# at the planted paths now would be the stale lock the entrypoint should remove.
if [ -L "$LOCKDIR/lock" ] || [ -e "$LOCKDIR/.parentlock" ]; then
  echo "error: entrypoint did not remove the stale lock in $LOCKDIR" >&2
  exit 1
fi
echo "ok: entrypoint removed the stale lock"

# --- 7. Smoke test (full MCP session) -------------------------------------
echo
echo "== [7/7] smoke test =="
set +e
SMOKE_OUT="$(
  BASE="http://127.0.0.1:${MCP_PORT}" \
  FIREFOX_MCP_KEY="$KEY" \
  SMOKE_URL="http://127.0.0.1:${WEBPORT}/index.html" \
  HOME="$HOMEDIR" \
  PATH="$PATH_PREPEND:$PATH" \
  bash scripts/smoke-test.sh 2>&1
)"
RC=$?
set -e
printf '%s\n' "$SMOKE_OUT"
if [ "$RC" -ne 0 ]; then
  echo "error: smoke test failed (rc=${RC})" >&2
  echo "--- entrypoint log ---" >&2
  cat "$LOGS/entrypoint.log" >&2
  exit 1
fi
printf '%s' "$SMOKE_OUT" | grep -q "SMOKE TEST PASSED" || { echo "error: smoke test did not report success" >&2; exit 1; }
printf '%s' "$SMOKE_OUT" | grep -q "$MARKER" || { echo "error: page text marker not found (navigate/get_page_text failed)" >&2; exit 1; }
echo "ok: full MCP session worked; page text matched the local marker"

echo
echo "E2E PASSED"
