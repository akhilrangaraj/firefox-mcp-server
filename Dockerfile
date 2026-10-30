FROM node:22-slim

ENV NODE_ENV=production

WORKDIR /app

# Firefox ESR + fonts + curl (curl is used for the container HEALTHCHECK).
RUN apt-get update && apt-get install -y --no-install-recommends \
        firefox-esr \
        fonts-liberation \
        fonts-noto-color-emoji \
        fonts-freefont-ttf \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/firefox-esr /usr/local/bin/firefox

# MCP server (bundles geckodriver + selenium-webdriver as npm deps) + the
# stdio->HTTP bridge (supergateway). Pinned for reproducible builds.
RUN npm install -g --no-audit --no-fund \
        @mozilla/firefox-devtools-mcp@0.10.7 \
        supergateway@4.2.1

# Pre-install the geckodriver binary onto PATH. firefox-devtools-mcp's
# findGeckodriver() checks PATH first, so this makes driver discovery
# deterministic -- no runtime download, no homedir-cache dependency, works for
# any user. (Validated: downloads a real, runnable geckodriver ELF.)
RUN set -eux; \
    cd /tmp; \
    npm install --no-save --no-audit --no-fund geckodriver@6.0.2; \
    GECKODRIVER_CACHE_DIR=/tmp/geo node --input-type=module -e 'import { download } from "geckodriver"; import { copyFileSync, chmodSync } from "node:fs"; const p = await download(); copyFileSync(p, "/usr/local/bin/geckodriver"); chmodSync("/usr/local/bin/geckodriver", 0o755); console.log("geckodriver ->", p);'; \
    /usr/local/bin/geckodriver --version; \
    rm -rf /tmp/node_modules /tmp/package.json /tmp/package-lock.json /tmp/geo

# Non-root user. /data holds the persistent Firefox profile (a PVC is mounted
# there at runtime); the MCP server's own scratch dir lives under /home.
RUN groupadd -g 1000 appuser \
    && useradd -m -u 1000 -g 1000 appuser \
    && mkdir -p /data/ff-profile /home/appuser/.firefox-devtools-mcp \
    && chown -R appuser:appuser /data /home/appuser/.firefox-devtools-mcp
USER appuser

ENV FIREFOX_PATH=/usr/local/bin/firefox \
    FIREFOX_PROFILE=/data/ff-profile \
    MCP_PORT=8931 \
    MCP_HOST=0.0.0.0 \
    VIEWPORT=1280x720 \
    TOOL_PRESET=basic

EXPOSE 8931
# Reliable liveness: the MCP endpoint is POST/JSON-RPC, so probe the TCP port
# (supergateway listening) instead of doing an HTTP GET at /mcp.
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD node -e 'const n=require("net");const s=n.connect(8931,"127.0.0.1",()=>{s.end();process.exit(0)});s.on("error",()=>process.exit(1));setTimeout(()=>process.exit(1),3000)'

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
