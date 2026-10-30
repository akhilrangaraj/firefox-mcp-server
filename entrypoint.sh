#!/bin/sh
# Bridge the stdio-based Firefox MCP server over Streamable HTTP so it can be
# reached across the network (via kubectl port-forward).
#
#   supergateway (Streamable HTTP :8931/mcp)
#        |  stdio
#        v
#   firefox-devtools-mcp  (spawns + drives headless Firefox via geckodriver/BiDi)
#
# One long-lived browser per session (stateful mode). NOTE: supergateway spawns
# a NEW stdio child (=> a new Firefox) for every MCP session, and every child
# uses the same profile dir -- so only ONE session at a time can drive the
# browser (the profile is locked). Abandoned sessions are reaped by
# --sessionTimeout so the lock is released. Profile persists on a PVC.
set -eu

MCP_PORT="${MCP_PORT:-8931}"
MCP_HOST="${MCP_HOST:-0.0.0.0}"
FF_PATH="${FIREFOX_PATH:-/usr/local/bin/firefox}"
PROFILE="${FIREFOX_PROFILE:-/data/ff-profile}"
VIEWPORT="${VIEWPORT:-1280x720}"
TOOL_PRESET="${TOOL_PRESET:-basic}"
EXTRA_ARGS="${MCP_EXTRA_ARGS:-}"

# --- Session handling -------------------------------------------------------
# supergateway's --stateful spawns a new stdio child (and thus a new Firefox)
# per MCP session. They all share one profile dir, so a second concurrent
# session can't launch (profile lock). Reap abandoned sessions after this many
# ms so they release the profile lock. 900000 = 15 min.
SESSION_TIMEOUT_MS="${MCP_SESSION_TIMEOUT_MS:-900000}"

# --- Authentication ---------------------------------------------------------
# The API key is the ONLY defence against DNS rebinding / unauthenticated
# drive-by use, so fail closed unless explicitly disabled.
MCP_API_KEY_FILE="${MCP_API_KEY_FILE:-/run/secrets/mcp/api-keys}"
MCP_AUTH_DISABLED="${MCP_AUTH_DISABLED:-0}"

AUTH_ENABLED=1
if [ "${MCP_AUTH_DISABLED}" = "1" ]; then
    AUTH_ENABLED=0
    echo "[entrypoint] *** WARNING: MCP_AUTH_DISABLED=1 -- starting WITHOUT an API key ***" >&2
    echo "[entrypoint] *** Anyone who can reach ${MCP_HOST}:${MCP_PORT} can drive this logged-in browser. ***" >&2
else
    if [ ! -f "${MCP_API_KEY_FILE}" ] || [ ! -s "${MCP_API_KEY_FILE}" ]; then
        {
            echo "[entrypoint] ERROR: API key file '${MCP_API_KEY_FILE}' is missing or empty." >&2
            echo "[entrypoint] ERROR: mount the 'firefox-mcp-auth' Secret at /run/secrets/mcp (key: api-keys)" >&2
            echo "[entrypoint] ERROR: or set MCP_AUTH_DISABLED=1 to start without auth (NOT recommended)." >&2
        }
        exit 1
    fi
fi

# --- Tool surface -----------------------------------------------------------
# Default: the "basic" preset minus webextension and screencast.
#   - screencast needs Firefox 154+; this image ships Debian ESR 140 -> broken.
#   - webextension (install_extension) can persist an extension into the
#     logged-in profile -> a privilege/persistence risk.
# Set MCP_TOOLS="" to fall back to the TOOL_PRESET instead.
MCP_TOOLS_DEFAULT="pages,snapshot,input,screenshot,print,downloads,script,utilities,management"
if [ -z "${MCP_TOOLS+x}" ]; then
    MCP_TOOLS="${MCP_TOOLS_DEFAULT}"
fi
if [ -n "${MCP_TOOLS}" ]; then
    TOOLS_SPEC="--tools ${MCP_TOOLS}"
else
    TOOLS_SPEC="--toolPreset ${TOOL_PRESET}"
fi

STDIO_CMD="firefox-devtools-mcp --headless --viewport ${VIEWPORT} --firefoxPath ${FF_PATH} --profilePath ${PROFILE} ${TOOLS_SPEC} --startUrl about:blank ${EXTRA_ARGS}"

# --- Stale profile lock -----------------------------------------------------
# This ReadWriteOnce PVC is mounted by exactly this one container and Firefox
# is not running yet, so any lock left in the profile dir is stale (crash /
# SIGKILL / node eviction). Remove it so a fresh launch isn't blocked by a
# lock owned by a dead process. On Linux `lock` is a dangling symlink to
# "<ip>:+<pid>", so test nothing (`[ -f ]` is false for it) -- just rm -f.
rm -f "${PROFILE}/lock" "${PROFILE}/.parentlock"

# --- CWD for relative save paths -------------------------------------------
# The MCP server resolves relative save paths against the process CWD. Point
# it at a writable scratch dir so downloads/screenshots land somewhere safe.
: "${HOME:=/tmp}"
mkdir -p "${HOME}/.firefox-devtools-mcp"
cd "${HOME}/.firefox-devtools-mcp"

echo "[entrypoint] supergateway -> stdio MCP over Streamable HTTP"
echo "[entrypoint]   listen : ${MCP_HOST}:${MCP_PORT}   (endpoint: /mcp, health: /healthz)"
echo "[entrypoint]   auth   : $([ "${AUTH_ENABLED}" = "1" ] && echo "on (file ${MCP_API_KEY_FILE})" || echo "DISABLED")"
echo "[entrypoint]   session: timeout=${SESSION_TIMEOUT_MS}ms, tools=${MCP_TOOLS:-<preset ${TOOL_PRESET}>}"
echo "[entrypoint]   stdio  : ${STDIO_CMD}"

if [ "${AUTH_ENABLED}" = "1" ]; then
    exec supergateway \
      --apiKeyFile "${MCP_API_KEY_FILE}" \
      --stdio "${STDIO_CMD}" \
      --outputTransport streamableHttp \
      --stateful \
      --sessionTimeout "${SESSION_TIMEOUT_MS}" \
      --healthEndpoint /healthz \
      --port "${MCP_PORT}" \
      --host "${MCP_HOST}"
else
    exec supergateway \
      --stdio "${STDIO_CMD}" \
      --outputTransport streamableHttp \
      --stateful \
      --sessionTimeout "${SESSION_TIMEOUT_MS}" \
      --healthEndpoint /healthz \
      --port "${MCP_PORT}" \
      --host "${MCP_HOST}"
fi
