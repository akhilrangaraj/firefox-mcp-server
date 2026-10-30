# firefox-mcp-server

A **stateful** Firefox browser in Kubernetes, exposed to your MCP clients over
**Streamable HTTP** (`/mcp`). It runs the official
[`@mozilla/firefox-devtools-mcp`](https://github.com/mozilla/firefox-devtools-mcp)
server (v0.10.7) driving a real headless Firefox ESR via WebDriver BiDi, bridged
to HTTP by [`supergateway`](https://github.com/supercorp-ai/supergateway) (v4.2.1).

One persistent browser per pod with a profile on a PVC, so **logins and cookies
survive** across requests and pod restarts. You reach it cluster-internal via
`kubectl port-forward` (no public exposure).

```
   your MCP client (Claude Code / Cursor / Cline / any MCP SDK)
            |  MCP over HTTP  (POST /mcp)
            v
   +-----------------------------------------------------------+
   |  firefox-mcp (StatefulSet, 1 replica)                     |
   |   supergateway (Streamable HTTP :8931)                    |
   |        | stdio                                            |
   |        v                                                  |
   |   @mozilla/firefox-devtools-mcp  (35 tools)               |
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
- A single long-lived browser (`--stateful`) + a profile on a PVC = a real,
  persistent, logged-in browser session you can drive from anywhere you can
  `port-forward`.

## Verified locally (on this machine, no cluster)

- `supergateway` bridged `@mozilla/firefox-devtools-mcp@0.10.7` over
  Streamable HTTP at `/mcp`.
- MCP `initialize` succeeded; `tools/list` returned **35 tools**
  (`navigate_page`, `take_snapshot`, `click_by_uid`, `fill_by_uid`,
  `screenshot_page`, `evaluate_script`, `print_page`, `list_pages`, ...).
- Not tested locally: the actual Firefox launch (no browser installed here) --
  the container image provides Firefox ESR.

## Quickstart

```bash
# 1. Build + push
REGISTRY=registry.example.com/akhil ./scripts/build.sh --push

# 2. Deploy (needs a StorageClass for the profile PVC)
REGISTRY=registry.example.com/akhil ./scripts/deploy.sh

# 3. Reach it (cluster-internal)
./scripts/port-forward.sh &

# 4. Smoke test (MCP initialize + tools/list + a real navigation)
./scripts/smoke-test.sh

# 5. Point your MCP client at it
cp client/mcp-client.example.json  # merge into your client's config
```

### MCP client config

Streamable HTTP (modern clients -- Claude Code, Cursor, Cline, MCP SDK >= 1.x):

```json
{ "mcpServers": { "firefox": { "type": "http", "url": "http://127.0.0.1:8931/mcp" } } }
```

Legacy SSE clients: run supergateway with `--outputTransport sse` (see
`entrypoint.sh`) and use `url: http://127.0.0.1:8931/sse`.

## Layout

```
Dockerfile                 node:22-slim + Firefox ESR + MCP server + supergateway
entrypoint.sh              supergateway (stdio->Streamable HTTP) -> MCP server
k8s/namespace.yaml         namespace: firefox-mcp
k8s/statefulset.yaml       1 replica, non-root, profile PVC (volumeClaimTemplate)
k8s/service.yaml           headless ClusterIP :8931
k8s/networkpolicy.yaml     egress: internet only (anti-SSRF)
client/mcp-client.example.json
scripts/                   build / deploy / port-forward / smoke-test
```

## Tuning

- **Tool surface**: set `TOOL_PRESET` to `slim | basic | developer | mozilla | all`
  (default `basic`). `developer` adds network/console/debugger; `mozilla`/`all`
  add privileged tools (requires `MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1`).
- **Viewport**: `VIEWPORT=1280x720`.
- **Extra flags**: append to `MCP_EXTRA_ARGS`, e.g.
  `MCP_EXTRA_ARGS="--acceptInsecureCerts"`.
- **Persistence**: the profile is at `/data/ff-profile` (PVC). Delete the PVC
  to wipe logins.

## Security notes

- **Anti-SSRF egress policy** blocks private / loopback / link-local /
  metadata (`169.254.0.0/16`) ranges so a prompt-injected page can't be used
  to probe in-cluster services or the cloud metadata endpoint.
- Runs **non-root**, drops all capabilities, `seccompProfile: RuntimeDefault`.
- **Prompt injection**: pages can contain instructions aimed at the agent.
  Only browse sites you trust with a logged-in profile.
- The browser holds your real cookies -- treat this pod like a machine that is
  logged in. On **k3s**, NetworkPolicy needs `--enable-network-policy`.
