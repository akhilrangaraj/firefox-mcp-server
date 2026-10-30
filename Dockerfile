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

# Non-root user: reuse the base image's `node` user, which already owns
# uid/gid 1000 (creating another uid-1000 user fails). /data holds the
# persistent Firefox profile (a PVC is mounted there at runtime); the MCP
# server's own scratch dir lives under $HOME.
RUN mkdir -p /data/ff-profile /home/node/.firefox-devtools-mcp \
    && chown -R node:node /data /home/node/.firefox-devtools-mcp
USER node

ENV FIREFOX_PATH=/usr/local/bin/firefox \
    FIREFOX_PROFILE=/data/ff-profile \
    MCP_PORT=8931 \
    MCP_HOST=0.0.0.0 \
    VIEWPORT=1280x720 \
    TOOL_PRESET=basic

EXPOSE 8931
# supergateway serves GET /healthz with 200 "ok" (registered before the
# API-key check, so no key is needed).
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8931/healthz || exit 1

# COPY always creates root-owned files, and a RUN chmod here would execute as
# `node` and fail -- so set the mode at copy time.
COPY --chmod=0755 entrypoint.sh /app/entrypoint.sh
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
