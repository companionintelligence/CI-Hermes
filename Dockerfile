# CI-Hermes
# Web terminal wrapper around the official Hermes Agent image for the CI marketplace

# To update: docker buildx imagetools inspect nousresearch/hermes-agent:v2026.7.30
FROM nousresearch/hermes-agent:v2026.7.30@sha256:b869e64d6496d4763d5e4fb675b5f504cb23b0e35ec9b790481a56118602b10f

USER root

# Install Node.js (for terminal web server) and build tools (for node-pty native addon)
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl make g++ && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install server dependencies
COPY package.json /app/
RUN cd /app && npm install --omit=dev

# Bundle CI-managed context in the image. Hermes enables the runtime plugin
# and external skill directory from config.yaml at startup; the files themselves
# stay outside /opt/data so the agent cannot edit managed instructions.
COPY server.cjs memory-gate.cjs terminal.html logo.webp entrypoint.sh gateway-entrypoint.sh start-hermes.sh bootstrap-ci-context.sh bootstrap-from-hub.sh configure-ci-server.py configure-hub-mcp.py /app/
COPY assets /app/assets
# Opt-out Sentry error reporting for the wrapper. Required by server.cjs on every
# boot; inert without SENTRY_DSN. No build ARG needed — unlike the fleet's web
# bundles this DSN is read at runtime, never baked into the image, so the
# CI_TELEMETRY kill switch always reaches it.
COPY telemetry /app/telemetry
COPY ci-context/skills /app/ci-context/skills
COPY ci-context/plugins/ci-runtime /opt/hermes/plugins/ci-runtime
COPY ci-context/plugins/companionintelligence /app/ci-context/plugins/companionintelligence
RUN chmod +x /app/entrypoint.sh /app/gateway-entrypoint.sh /app/start-hermes.sh /app/bootstrap-ci-context.sh /app/bootstrap-from-hub.sh

# CI-Hermes: native Ollama (/api/chat) adapter. The upstream agent talks to Ollama
# via the OpenAI-compat /v1 endpoint, which silently ignores per-request num_ctx
# (verified through Ollama v0.30.11/main) — so models load at Ollama's 4096 default.
# This patch routes local Ollama onto the native /api/chat API (which honors num_ctx)
# via a drop-in client + a startup .pth shim. Inert unless CI_HERMES_OLLAMA_NATIVE=1
# at runtime. See specs/ci/ci-hermes-ollama-native-api-plan.md and CI-Hermes#24.
COPY patches/ollama_native_adapter.py patches/enable_ollama_native.py patches/ci-ollama-native.pth /app/patches/
RUN SP="$(/opt/hermes/.venv/bin/python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')" && \
    install -m 0644 /app/patches/ollama_native_adapter.py "$SP/ollama_native_adapter.py" && \
    install -m 0644 /app/patches/enable_ollama_native.py  "$SP/enable_ollama_native.py" && \
    install -m 0644 /app/patches/ci-ollama-native.pth     "$SP/ci-ollama-native.pth" && \
    /opt/hermes/.venv/bin/python -c "import enable_ollama_native" && \
    echo "CI ollama-native patches installed into $SP"

# Ensure hermes venv is in PATH everywhere. The agent's terminal tool spawns
# subprocesses that may not inherit Docker ENV, so we cover all cases:
# - ENV: for the entrypoint, Node server, and direct child processes
# - /etc/profile.d/: for login shells (which /etc/profile resets PATH on)
# - symlink: guarantees `hermes` is found regardless of how the shell is spawned
ENV PATH="/opt/hermes/.venv/bin:${PATH}"
RUN echo 'export PATH="/opt/hermes/.venv/bin:$PATH"' > /etc/profile.d/hermes-venv.sh && \
    ln -s /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes

# Match the CI app UID/GID using the base image's existing hermes user.
# The official Hermes Docker entrypoint also expects this user to exist when
# the gateway service drops privileges.
RUN groupmod -o -g 1000 hermes && \
    usermod -u 1000 -g 1000 -d /opt/data -s /bin/bash hermes

# The dashboard's first-run npm build and opt-in `hermes --tui` setup write
# under /opt/hermes/. Since we run as UID 1000 (via compose user:), fix
# ownership at build time.
# Dashboard needs web/ and hermes_cli/web_dist/; TUI needs ui-tui/ for its
# first-run npm install/build. Both use /.npm for cache.
RUN mkdir -p /opt/hermes/hermes_cli/web_dist && \
    chown -R 1000:1000 /opt/hermes/web/ /opt/hermes/ui-tui/ /opt/hermes/hermes_cli/web_dist/ && \
    mkdir -p /.npm && chown -R 1000:1000 /.npm

# UID/GID set via user: 1000:1000 in docker-compose.yml
ENTRYPOINT ["/app/entrypoint.sh"]
EXPOSE 18789
