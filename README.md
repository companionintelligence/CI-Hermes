<img width="512" height="512" alt="logo" src="https://github.com/user-attachments/assets/85774db5-bd25-4b82-88b2-05d0a58c0b28" />

# Hermes - Companion Memory Edition


> Web terminal and [official Hermes dashboard](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard) for running [Hermes Agent](https://hermes-agent.nousresearch.com) on the Companion Intelligence (CI) marketplace.

<img width="225" height="224" alt="logo-alt" src="https://github.com/user-attachments/assets/b4c0ae9d-9efc-43a1-986c-e829fd22add2" />

## [Designed to run with Companion Memory](https://hub.ci.computer/store/ci-memory)

### Connect Hermes to CI Memory

Hermes ships with the Companion Intelligence memory provider already installed.
There are two ways to connect it to your Companion Memory Server:

- **Automatic (recommended)** — first generate an API key (**Step 1** below),
  then enter the URL (`http://host.docker.internal:8642`) and that key into the
  **Companion Memory URL** and **Companion Memory API Key** fields of the Hermes
  **install dialog**. The provider is enabled and selected as your active
  memory backend automatically — no terminal step needed. On a brand-new
  install it activates on the **first restart after install** (the app needs
  one startup to generate its config before the provider can be selected), so
  restart the Hermes app once from the CI marketplace if memory isn't active
  yet. If you later switch providers by hand, your choice is preserved across
  restarts.
- **Manual** — leave those install fields blank and run the interactive
  `hermes memory setup` wizard later, as described in **Step 2**.

#### Step 1 — Install Companion Memory and generate an API key (do this first)

Hermes connects *to* a running Companion Memory Server, so set that up before
touching the Hermes terminal:

1. In the **CI marketplace**, install the **[Companion Memory](https://hub.ci.computer/store/ci-memory)**
   app and wait for it to finish starting.
2. **Open the Companion Memory app** and complete its onboarding if prompted.
3. Go to **Settings → API Keys**, click the **`+`** button, give the key a name
   (e.g. `Hermes`), optionally set an expiry, and click **Create**.
4. **Copy the key immediately** — it is shown only once and cannot be retrieved
   later. Keep it handy for Step 2.

#### Step 2 — Run memory setup in the Hermes terminal

> **Important — chat mode vs. CLI mode.** When you open the Hermes terminal (the
> CI marketplace app, e.g.
> `https://<your-host>.companionintelligence.com/terminal`), it drops you
> straight into **chat with Hermes**. `hermes memory setup` is a command-line
> command, **not** a chat message — if you type it at the chat prompt (`❯`)
> Hermes just answers it like a question and nothing gets configured. You must
> switch to the shell first.

1. **Open the Hermes terminal** from the CI marketplace (the `/terminal` path).
   You'll land in chat mode by default.
2. **Press `Ctrl+D`** to exit chat and drop into the underlying shell (CLI mode).
   You'll see a normal shell prompt instead of the `❯` chat prompt.
3. Have the **API key from Step 1** ready — if you leave it blank and no key is
   already set in `CI_SERVER_TOKEN`, the wizard cancels.
4. At the shell, run:

   ```
   hermes memory setup
   ```

   If `companionintelligence` is the only memory provider, the wizard starts its
   setup directly; otherwise **select `companionintelligence`** from the list (it
   is pre-installed — no extra install step needed).
5. **CI-Server URL** — at the `CI-Server URL [http://127.0.0.1:8642]:` prompt,
   enter:

   ```
   http://host.docker.internal:8642
   ```

   > ⚠️ **Do not accept the `http://127.0.0.1:8642` default.** Inside the Hermes
   > container `127.0.0.1` is Hermes itself, not the Memory Server. The Companion
   > Memory app publishes its gateway on the **host** at port `8642`, and Hermes
   > reaches the host via `host.docker.internal` (the same way it reaches the CI
   > Hub). So use `http://host.docker.internal:8642`.
   >
   > If host-gateway access is ever blocked, the Memory gateway also joins the
   > shared CI network — `http://gateway:8642` works as a fallback.

6. **API key** — paste the key from **Step 1** and press Enter. If a key is
   already set in `CI_SERVER_TOKEN`, leaving this blank keeps the current key;
   otherwise leaving it blank prints `✗ Both URL and API key are required. Setup cancelled.` and exits without saving.
7. The wizard runs a **connection test** (`GET /api/health`) against the URL with
   your key. **Nothing is saved unless it succeeds** — if you see an error, fix
   the URL/key and run `hermes memory setup` again. On success it saves the key
   to `.env`, the URL to `companionintelligence/config.json`, and sets
   `memory.provider: companionintelligence` in `config.yaml`.
8. Open the Hermes **`/plugins`** page and **enable the `companionintelligence` plugin** from the list.
9. **Restart the Hermes app** from the CI marketplace. Memory is now active in both the terminal (`/terminal`) and the web chat (`/chat`).

> **Tip:** While in CLI mode you can also run other admin commands such as
> `hermes model` and `hermes doctor`. Press `Ctrl+D` from chat any time you need
> the shell.



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

To connect it to Companion Memory you have two options (see *Connect Hermes to CI Memory* above for the full walkthrough): enter the **Companion Memory URL** and **API Key** in the app's install dialog and it activates automatically on startup, or run `hermes memory setup` in the terminal and follow the instructions. Either way, generate your API key from the CI-Server settings page.

## Hub MCP (platform tools)

On CI marketplace installs with MCP enabled, the Hub injects `HUB_MCP_URL` and `HUB_MCP_API_KEY`. Bootstrap order is:

1. `/app/bootstrap-from-hub.sh` — creates `config.yaml` when missing (skips if one already exists)
2. `/app/bootstrap-ci-context.sh` — runs `configure-ci-server.py` (optional CI-Server memory MCP) and `configure-hub-mcp.py` (Hub platform MCP)

The Hub block is written under `mcp_servers.hub` pointing at the Hub's Streamable HTTP MCP endpoint (`…/api/mcp`) with `Authorization: Bearer` headers and **no** `transport:` line (the agent's default MCP client speaks Streamable HTTP). It mirrors the optional `ci_server` memory MCP block, with which it coexists.

Run the smoke tests:

```bash
bash tests/hub-mcp-smoke.sh
bash tests/configure-hub-mcp.test.sh
```

If Hub MCP is disabled on the Hub, run `cihub mcp setup` and restart the Hermes app to pick up new credentials.

## License

MIT
