# CI-Hermes

> Web terminal and [official Hermes dashboard](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard) for running [Hermes Agent](https://hermes-agent.nousresearch.com) on the Companion Intelligence (CI) marketplace.

⚠️ WARNING: Running this on systems other than the CI marketplace is likely very insecure. This configuration is only secure when running behind the CI app proxy.

## What is this?

This repo builds the CI marketplace wrapper image for Hermes Agent. It does not fork Hermes itself — it layers a terminal UI, onboarding flow, and CI runtime context on top of the [official Hermes Agent Docker image](https://github.com/NousResearch/hermes-agent). It provides:

- A web-based terminal UI (xterm.js) that drops you straight into chat with Hermes
- Automatic setup detection using Hermes' own runtime provider resolver — runs the setup wizard only when no usable provider credentials are configured
- The official Hermes web dashboard, proxied through the terminal server and protected by CI marketplace authentication
- A separate gateway container using the same wrapper image with a CI gateway entrypoint that launches Hermes in `gateway run` mode for messaging platform integrations
- Sandboxing so Hermes runs in its own environment that can't mess up other CI apps
- CI-specific runtime context and a `ci` skill, wired through Hermes' supported plugin/skills surfaces so the agent understands its containerized CI environment

## Architecture

Two containers share a single data volume (`/opt/data`):

- **web** — Node.js server providing the terminal UI (xterm.js + PTY) and the official Hermes dashboard (running as a background process, proxied via localhost). This is the main entry point behind the CI app proxy.
- **gateway** — Same wrapper image, running a dedicated CI gateway entrypoint that applies managed bootstrap and then executes `hermes gateway run`.

The terminal is served at `/terminal` (the CI marketplace app entry point). The dashboard owns `/` and all other paths are proxied to it, ensuring it's protected by CI marketplace authentication.

## CI context

The image includes a bundled `ci-runtime` plugin under `/opt/hermes/plugins` and a managed `ci` skill under `/app/ci-context/skills`. Both are app-owned image content, so they update with normal CI marketplace app image updates without writing managed prompt files into the user's persistent data directory.

On startup, `/app/bootstrap-ci-context.sh` idempotently:

- Enables the bundled `ci-runtime` plugin in `/opt/data/config.yaml`, so Hermes injects compact CI runtime context before LLM calls through the official `pre_llm_call` hook.
- Adds the managed skills directory to `skills.external_dirs` in `/opt/data/config.yaml` when the config exists.

To use it, simply enable it like any other hermes memory system by running `hermes memory setup` and following the instructions. You can get your API key for authentication from the CI-Server settings page.
## License

MIT
