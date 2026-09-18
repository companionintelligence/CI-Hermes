# CI-Hermes
# Web terminal wrapper around the official Hermes Agent image for the CI marketplace

# To update: docker buildx imagetools inspect nousresearch/hermes-agent:v2026.9.14
# (Hermes Agent v0.21.3). The digest is the multi-arch index digest, so one line
# pins both amd64 and arm64.
FROM nousresearch/hermes-agent:v2026.9.14@sha256:99641e57ec762c59e54cb44aa6746b7fc68c18b3c5ddb088af54234c613d9294

USER root

# Node and the native-addon toolchain come from the base image. Upstream ships
# node + npm at /usr/local/bin (Node 26 as of v2026.9.14) for its own dashboard
# and TUI builds, and gcc/g++/make/python3 for its Python extensions — which is
# everything node-pty's node-gyp build needs. /usr/local/bin precedes /usr/bin on
# the image PATH, so the NodeSource Node 22 this file used to apt-install was never
# the `node` that ran server.cjs; it only added ~100MB and a third-party install
# script to every build. node-pty resolves to 1.1.x (node-addon-api), so it builds
# against whichever Node major upstream ships.
COPY package.json /app/
RUN cd /app && npm install --omit=dev

# Bundle CI-managed context in the image. Hermes enables the runtime plugin
# and external skill directory from config.yaml at startup; the files themselves
# stay outside /opt/data so the agent cannot edit managed instructions.
COPY server.cjs memory-gate.cjs hub-env.cjs hub-env.sh terminal.html logo.webp entrypoint.sh gateway-entrypoint.sh start-hermes.sh bootstrap-ci-context.sh bootstrap-from-hub.sh reconcile-hub-config.py configure-ci-server.py configure-hub-mcp.py /app/
COPY assets /app/assets
# Opt-out Sentry error reporting for the wrapper. Required by server.cjs on every
# boot; inert without SENTRY_DSN.
#
# This DSN is read from the process env at runtime — there is no web bundle here,
# so nothing is compiled in the way the fleet's Vite apps are. But nothing supplies
# it at runtime either: the marketplace runs this published image as-is, which is
# why the wrapper has reported nothing since telemetry landed. Released images are
# therefore built with `--build-arg SENTRY_DSN=…` and the value is re-exported as
# ENV below, so a marketplace install reports out of the box.
#
# Built without the arg (local `docker build`) the ARG default is empty, which
# resolveTelemetrySettings already treats as unset (disabledReason "no-dsn") —
# nothing initialises and no outbound connection is opened.
#
# Baking the DSN does not weaken the kill switches: CI_TELEMETRY=off (what the
# marketplace "Share crash reports" toggle sets) and CI_LOCAL_ONLY=true are
# separate runtime vars and both still beat a baked-in DSN. A runtime
# `-e SENTRY_DSN=…` also still overrides this value.
ARG SENTRY_DSN=""
ARG SENTRY_RELEASE=""
ENV SENTRY_DSN=${SENTRY_DSN} \
    SENTRY_RELEASE=${SENTRY_RELEASE}
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
#
# The shim wraps private upstream functions by name and degrades to stock /v1 (and
# Ollama's 4096-token default window) if any of them is renamed — silently, by
# design, so a bad patch can never crash startup. check_ollama_native_contract.py
# turns that silent regression into a build failure: it parses the upstream source
# baked into /opt/hermes and refuses the image if a hook target or one of the
# helpers the shim imports is gone. Run it before the import so a rename is
# reported by name rather than as "import worked, nothing happened".
COPY patches/ollama_native_adapter.py patches/enable_ollama_native.py patches/ci-ollama-native.pth patches/check_ollama_native_contract.py /app/patches/
RUN SP="$(/opt/hermes/.venv/bin/python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')" && \
    /opt/hermes/.venv/bin/python /app/patches/check_ollama_native_contract.py --root /opt/hermes && \
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
