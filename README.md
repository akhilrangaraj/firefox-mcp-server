# firefox-mcp-server

A **stateful** Firefox browser in Kubernetes, exposed to your MCP clients over
**Streamable HTTP** (`/mcp`). It runs the official
[`@mozilla/firefox-devtools-mcp`](https://github.com/mozilla/firefox-devtools-mcp)
server (v0.10.7) driving a real headless Firefox ESR via WebDriver BiDi, bridged
to HTTP by [`supergateway`](https://github.com/supercorp-ai/supergateway) (v4.2.1).

One persistent browser per instance with a profile on a PVC, so **logins and
cookies survive** across requests and pod restarts. You reach it cluster-internal
via `kubectl port-forward` (no public exposure), and it is **API-key protected**.

```
   your MCP client (Claude Code / Cursor / Cline / any MCP SDK)
            |  MCP over HTTP  (POST /mcp,  Authorization: Bearer <key>)
            v
   +-----------------------------------------------------------+
   |  firefox-mcp (StatefulSet, 1 replica)                     |
   |   supergateway (Streamable HTTP :8931, API-key auth)      |
   |        | stdio                                            |
   |        v                                                  |
   |   @mozilla/firefox-devtools-mcp  (tool surface below)     |
   |        | WebDriver BiDi / geckodriver                     |
   |        v                                                  |
   |   Firefox ESR (headless)  -- profile on PVC (/data)       |
   +-----------------------------------------------------------+
            |  egress: internet only (NetworkPolicy, anti-SSRF)
            v
         the public web
```

## Why this shape

- `firefox-devtools-mcp` is **stdio-only** (no `--port`), so it can't be
  exposed directly over the network. `supergateway` bridges stdio ->
  Streamable HTTP (and SSE) with zero changes to the server.
- The MCP server **launches and owns** the Firefox process, so everything fits
  in one container; Marionette binds loopback inside it.
- A long-lived browser (`--stateful`) + a profile on a PVC = a real, persistent,
  logged-in browser session you can drive from anywhere you can `port-forward`.

## What `tests/local-e2e.sh` verifies

`tests/local-e2e.sh` runs the **real** `entrypoint.sh` -> `supergateway` ->
`@mozilla/firefox-devtools-mcp` -> a **real headless Firefox**, with no docker
and no cluster. It installs the two pinned packages into a temp dir, downloads a
real Firefox (cached and reused across runs), and then asserts:

- the entrypoint **refuses to start** (non-zero exit, clear message) when the
  API key file is missing and `MCP_AUTH_DISABLED` is not set;
- a **stale** profile `lock` / `.parentlock` (simulated crash) does **not**
  prevent launch;
- `GET /healthz` answers `200 ok` (no key required);
- a request **without** the key gets **HTTP 401**;
- a full MCP session works end-to-end: `initialize` ->
  `notifications/initialized` -> `tools/list` -> `navigate_page` -> `get_page_text`
  -> `DELETE` session, with the page text taken from a **local** `http.server`
  (no internet needed) and matched against a unique marker.

Run it any time: `bash tests/local-e2e.sh`.

What it does **not** cover: the image itself (Debian Firefox ESR 140; the test
uses the current Firefox release, so version-gated behaviour can differ), the
k8s manifests, and two concurrent MCP sessions contending for the profile lock.

## Quickstart

```bash
# 1. Build + push (defaults to registry.rangaraj.net/akhilrangaraj)
./scripts/build.sh --push

# 2. Deploy (needs a StorageClass for the profile PVC).
#    Creates the firefox-mcp-auth secret with a random key if missing.
./scripts/deploy.sh

# 3. Read back the API key (deploy.sh prints this command)
kubectl -n firefox-mcp get secret firefox-mcp-auth -o jsonpath='{.data.api-keys}' | base64 -d

# 4. Reach it (cluster-internal)
./scripts/port-forward.sh &

# 5. Smoke test (401 check + healthz + initialize + tools/list + navigate + text)
FIREFOX_MCP_KEY=<key> ./scripts/smoke-test.sh

# 6. Point your MCP client at it -- merge client/mcp-client.example.json into
#    your client's config (it is a JSON snippet, not a file to copy into place)
```

## Authentication

`supergateway` requires an API key on every MCP request unless explicitly
disabled. The key is the **only** defence against unauthenticated drive-by use
and DNS-rebinding, so the entrypoint **fails closed**: it exits non-zero if the
key file is missing or empty.

- **Where the key lives in-cluster:** the `firefox-mcp-auth` Secret, key
  `api-keys`, mounted read-only at `/run/secrets/mcp/api-keys`
  (env `MCP_API_KEY_FILE` overrides the path). `scripts/deploy.sh` generates a
  random key with `openssl rand -hex 24` if the Secret is missing and never
  prints it; read it back with the command it shows.
- **How a client sends it:** `Authorization: Bearer <key>` (or
  `X-API-Key: <key>`). The smoke test and the example client config use
  `Authorization: Bearer`.
- **Local / one-off:** write the key(s) to a file (one per line) and point
  `MCP_API_KEY_FILE` at it.
- **Disable (not recommended):** set `MCP_AUTH_DISABLED=1`; the entrypoint
  prints a loud warning and starts with no key.

### MCP client config

Streamable HTTP (modern clients -- Claude Code, Cursor, Cline, MCP SDK >= 1.x):

```json
{ "mcpServers": { "firefox": {
    "type": "http",
    "url": "http://127.0.0.1:8931/mcp",
    "headers": { "Authorization": "Bearer ${FIREFOX_MCP_KEY}" }
} } }
```

Set `FIREFOX_MCP_KEY` in the client's environment (many clients expand
`${ENV_VAR}` in headers). See `client/mcp-client.example.json`.

Legacy SSE clients: run supergateway with `--outputTransport sse` (see
`entrypoint.sh`) and use `url: http://127.0.0.1:8931/sse`.

## Sessions: one active MCP session per instance

`supergateway --stateful` spawns a **new stdio child (a new Firefox) for every
MCP session**, and every child is given the **same** profile directory. A
Firefox profile can only be opened by one browser at a time, so effectively
**only one session can drive the browser at a time**; a second concurrent
session will not be able to launch (profile lock) and its requests will fail.

- A session ends when the client sends `DELETE /mcp`, or after
  `MCP_SESSION_TIMEOUT_MS` (default `900000` = 15 min) of idleness -- whichever
  first. Reaping an abandoned session is what releases the profile lock.
- **For several users, deploy one instance per user** (one StatefulSet replica
  + its own profile PVC each), not several clients against one instance.

## Tool surface

The MCP server exposes tools in *modules*. `MCP_TOOLS` (comma-separated module
names) selects them; if you set it to the empty string it falls back to
`TOOL_PRESET` (`slim | basic | developer | mozilla | all`).

- **Default `MCP_TOOLS`** is the `basic` preset **minus** `webextension` and
  `screencast`:
  `pages,snapshot,input,screenshot,print,downloads,script,utilities,management`.
- **`webextension`** (`install_extension`) is excluded because it can persist an
  extension into the **logged-in** profile -- a persistence/privilege risk.
- **`screencast`** is excluded because it needs Firefox 154+, while this image
  ships ESR 140 (see below) -- it can never work here.
- **`script`** (`evaluate_script`) is **included**: it lets the agent run
  arbitrary JavaScript in logged-in pages. Powerful, but exactly as trusted (or
  untrusted) as the pages you point it at -- see the prompt-injection note.

## Firefox ESR version limits

The image ships **Firefox ESR 140** (Debian `firefox-esr`). Some tool modules
need newer Firefox and will not work on this image:

- **`screencast`** and **`profiler`**: require **Firefox 154+** -> unavailable.
- **`debugging`** (logpoints, breakpoints): requires **Firefox 153+** ->
  unavailable.

So the `developer` / `mozilla` / `all` presets are only useful for the modules
that don't depend on those features. The `local-e2e` test uses a newer Firefox
downloaded on the fly and is not bound by these limits.

## Layout

```
Dockerfile                 node:22-slim + Firefox ESR + MCP server + supergateway
entrypoint.sh              auth + supergateway (stdio->Streamable HTTP) -> MCP server
k8s/namespace.yaml         namespace: firefox-mcp
k8s/secret.example.yaml    firefox-mcp-auth Secret template (placeholder key)
k8s/statefulset.yaml       1 replica, non-root, profile PVC, secret mount, probes
k8s/service.yaml           headless ClusterIP :8931
k8s/networkpolicy.yaml     egress anti-SSRF + ingress (mcp-client label)
client/mcp-client.example.json   client config with Authorization header
scripts/                   build / deploy / port-forward / smoke-test
tests/local-e2e.sh         full local end-to-end test (no docker / cluster)
.gitea/workflows/          CI: build + push on push / tag / dispatch
```

## Tuning

- **Tool surface**: set `MCP_TOOLS` to a comma-separated module list, or to `""`
  to use `TOOL_PRESET` (`slim | basic | developer | mozilla | all`).
- **Session timeout**: `MCP_SESSION_TIMEOUT_MS` (default `900000`).
- **Viewport**: `VIEWPORT=1280x720`.
- **Extra flags**: append to `MCP_EXTRA_ARGS`, e.g.
  `MCP_EXTRA_ARGS="--acceptInsecureCerts"`.
- **Persistence**: the profile is at `/data/ff-profile` (PVC). Delete the PVC
  to wipe logins.

## Security notes

- **API key** is required on every MCP request (401 otherwise) and is the only
  control against **DNS rebinding** and unauthenticated use. There is no
  Origin/Host validation, so a browser on your workstation that can reach the
  `port-forward` could drive the browser **unless it presents the key** -- keep
  the key out of the browser and only in your MCP client.
- **k3s enforces NetworkPolicy by default** (via the embedded kube-router
  controller); it is only disabled by starting k3s with
  `--disable-network-policy`.
- **Egress anti-SSRF** blocks private / link-local / metadata
  (`169.254.0.0/16`) ranges so a prompt-injected page can't probe in-cluster
  services or the cloud metadata endpoint. **Loopback is NOT covered** --
  NetworkPolicies never apply to `127.0.0.0/8`, so the browser can still reach
  its own container's loopback (Marionette, etc.).
- **Ingress** policy allows TCP 8931 only from pods labelled `mcp-client:
  "true"` (any namespace). `kubectl port-forward` is unaffected (enters via the
  kubelet).
- Runs **non-root**, drops all capabilities, `seccompProfile: RuntimeDefault`.
- **Prompt injection**: pages can contain instructions aimed at the agent, and
  `script` can run JS in logged-in pages. Only browse sites you trust with a
  logged-in profile.
- The browser holds your real cookies -- treat this pod like a machine that is
  logged in.

## CI

`.gitea/workflows/build-and-push-image.yaml` builds and pushes the image on
push to any branch, on any tag, and on manual dispatch. It tags by short SHA
and by ref name, and additionally pushes `:latest` when the push is on the
default branch. It uses the `REGISTRY_USER` / `REGISTRY_PASS` secrets and logs
in to `registry.rangaraj.net`.

## How this repo was built (a small benchmark)

This is the stateful sibling of
[url-render-service](https://github.com/akhilrangaraj/url-render-service).
Both were built the same way on 2026-10-29: `qwen3.8-27b` (Q4_K_M, llama.cpp
on one Intel Arc B70, driven by
[Hermes Agent](https://github.com/NousResearch/hermes-agent)) wrote them, and
`claude-opus-5-5` in Claude Code audited and supervised. The url-render README
has the shared numbers: the first build of both repos in one conversation,
the audit, and the automatic skill review.

### Audit findings for this repo (Claude)

Claude checked every upstream claim against the published sources of
`@mozilla/firefox-devtools-mcp@0.10.7` and `supergateway@4.2.1`. qwen had
described the upstream packages accurately: every CLI flag, the preset
names, and the fact that the profile is used in place (so logins persist)
all checked out. The problems were in what it built around them:

| # | Finding | Severity |
|---|---------|----------|
| 1 | No authentication, although supergateway supports `--apiKey`. The default `basic` preset includes `evaluate_script` and `install_extension`, so any pod in the cluster could steal cookies from the logged-in browser or install an extension that persists on the PVC. | High |
| 2 | supergateway doesn't check `Origin` or `Host`, so a workstation `port-forward` could be driven through DNS rebinding by any website. | Medium |
| 3 | `--stateful` spawns a new stdio child, and so a new Firefox, **per MCP session**, all on one profile. The README described one long-lived browser; in fact a second concurrent session hits the profile lock. | Medium |
| 4 | Debian's Firefox ESR 140 can't run `screencast` (needs 154+), which the default preset advertises. | Low |
| 5 | The smoke test's grep required a space that compact JSON never has, so under `pipefail` it aborted before testing navigation. | Low |
| 6 | TCP-only probes, `publishNotReadyAddresses`, a broken `cp` line in the README, the k3s/Calico claim, and a no-op loopback egress rule. | Low |

### Fix (qwen, from a Claude-written spec)

qwen implemented the whole spec: fail-closed API-key auth, `--sessionTimeout`,
`/healthz` probes, a reduced tool set (`MCP_TOOLS`), stale profile-lock
cleanup, corrected NetworkPolicy, CI, and a rewritten smoke test. It also
added `tests/local-e2e.sh`, which runs the real entrypoint, supergateway, the
MCP server and a real headless Firefox with no docker. It checked its work
against the pinned upstream source and reported honestly what it hadn't run.

The run survived the model server being OOM-killed mid-run. The cause was
llama-server's host-RAM prompt cache; Hermes's retries carried the run
through the model reload.

### Review and final tweaks (Claude)

- **Lock cleanup that never ran:** the entrypoint checked
  `[ -f "$PROFILE/lock" ]`, but on Linux Firefox's `lock` is a dangling
  symlink, so the check is always false. It's now an unconditional `rm -f`.
- **Unrealistic lock test:** the e2e test planted regular files as the stale
  lock. It now plants a symlink the way Firefox does. With the old entrypoint
  that test still passed, because Firefox 159 recovers from such a lock on its
  own. So the bug was an ineffective check, not a launch failure, and the
  README now describes what the test actually proves.
- **Key in the process list:** `deploy.sh` now feeds the generated key to
  `kubectl` through stdin, so it never appears in `ps`.
- **Test coverage stated:** the README now lists what the e2e test doesn't
  cover: the ESR 140 image, the k8s manifests, and concurrent sessions.

### Token usage for this repo's fix

| Model | Phase | Calls | Input | of which cached | Output | Time |
|-------|-------|------:|------:|----------------:|-------:|-----:|
| qwen3.8-27b | Fix run (`qwen-task`), including the e2e test | 70 (+1 title) | 6,303,898 (+543) | 6,176,682 | 90,630 (+14) | 88 min |
| claude-opus-5-5 | Review, tweaks, e2e re-runs, this section | 15 | 34 uncached + 20,218 cache write | 4,105,380 | 8,262 | — |

The Firefox fix run cost about 3.7× the url-render fix in input and 1.8× in
output, and took twice as many calls. Its test had more moving parts: a real
Firefox and geckodriver downloaded locally, a bridged MCP session, and SSE
parsing. Each call also re-sends the whole conversation, so input grows
faster than the number of calls.
Claude's spec for this repo, and its share of the audit, are counted in
url-render-service's table.
