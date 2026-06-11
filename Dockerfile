# CI-Hermes
# Web terminal wrapper around the official Hermes Agent image for the CI marketplace

# To update: docker buildx imagetools inspect nousresearch/hermes-agent:v2026.6.5
FROM nousresearch/hermes-agent:v2026.6.5@sha256:9ad3b04ec916ea2c2da22358fd43b024c788d74073210695af88bfc2e63869b4

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
COPY server.cjs terminal.html logo.webp entrypoint.sh gateway-entrypoint.sh start-hermes.sh bootstrap-ci-context.sh bootstrap-from-hub.sh configure-ci-server.py /app/
COPY ci-context/skills /app/ci-context/skills
COPY ci-context/plugins/ci-runtime /opt/hermes/plugins/ci-runtime
COPY ci-context/plugins/companionintelligence /app/ci-context/plugins/companionintelligence
RUN chmod +x /app/entrypoint.sh /app/gateway-entrypoint.sh /app/start-hermes.sh /app/bootstrap-ci-context.sh /app/bootstrap-from-hub.sh

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
