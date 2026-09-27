# CLAUDE.md — CI-Hermes

> **Private & Confidential — Property of Lifescope Inc. Do not distribute.**

## Platform role

**CI-Hermes** sits in the **App** layer of the Companion Intelligence platform.

Architecture: `CI-Engineering/architecture/architecture.md`
Roadmap: `CI-Engineering/architecture/roadmap.md`
Issues: <https://github.com/companionintelligence/CI-Engineering/issues>

## What this repo does

CI marketplace wrapper for the NousResearch Hermes Agent. Provides a web terminal UI (xterm.js) and CI runtime context. Two containers: web (terminal + dashboard proxy) and gateway.

## Stack

- Node.js (web terminal server)
- xterm.js (browser terminal)
- Docker Compose (web + gateway containers)
- CI plugin/skill system

## Key commands

```bash
# Install dependencies
npm install

# Start development server / service
docker compose up --build

# Run tests (gated by .github/workflows/ci.yml)
npm test                 # unit (node --test) + shell suites in tests/
npm run test:unit
npm run test:sh          # needs python3 + PyYAML
# the bundled plugins' own suites
cd ci-context/plugins/companionintelligence && python3 -m unittest discover -p '*_test.py'
cd ci-context/plugins/ci-runtime && python3 -m unittest discover -p '*_test.py'
# the build-time patches' own suite (ollama native adapter + gateway health-auth shim; needs httpx)
cd patches && python3 -m unittest discover -p '*_test.py'

# Build for production
docker compose build
```

## LLM connection layer

Hermes talks to inference through two build-time shims layered on the upstream
image (`patches/`), each with a static AST contract check that runs in the
Docker build and fails it on upstream drift:

- `ollama_native_adapter.py` / `enable_ollama_native.py` — routes local Ollama
  through native `/api/chat` (honors `num_ctx`) instead of the OpenAI-compat
  `/v1` endpoint (silently drops it, falling back to Ollama's 4096-token
  default). Checked by `check_ollama_native_contract.py`.
- `enable_gateway_health_auth.py` — sends the gateway's Bearer key with the
  dashboard's `/health/detailed` probe. Checked by
  `check_gateway_health_auth_contract.py`.

`reconcile-hub-config.py` is the separate piece that keeps `config.yaml`'s
model/endpoint settings following the Hub's inference handout (ownership
tracking, the 64K context-window floor, cloud-handout precedence); see its
module docstring and `tests/hub-handout-restart.test.sh` for the contract.

Docker is not available in this environment to build/run the image — verify an
upstream Hermes base-image bump against a source clone instead (see the
`ci-hermes-upstream-bump-verification` memory note for the exact procedure).

## Package manager

**npm** — use exclusively; do not mix with npm/yarn/pnpm/bun unless the repo explicitly requires it.

## Cross-repo connections

- Calls **out** to CI-Hub's own MCP server — Hermes is the MCP client here.
  `configure-hub-mcp.py` registers it as `mcp_servers.hub` in `config.yaml`,
  pointed at Hub's Streamable HTTP endpoint (`…/api/mcp`). CI-Hub's generic
  marketplace app HTTP proxy (`hub_call_app_api`) can separately reach
  Hermes's own REST endpoints, but Hermes ships no `agents.mcp` /
  `agents.openapi` block in its marketplace `config.json`, so there is no
  structured MCP/OpenAPI bridge from Hub *into* Hermes today.
- ci-context plugin provides CI-Server awareness to Hermes (memory MCP,
  `configure-ci-server.py`) — a second, optional `mcp_servers.ci_server` entry
  alongside the Hub one.
- CI skill wired into Hermes plugin/skill surfaces

## Security

Only safe behind the CI marketplace app proxy. Do not expose directly to the internet.

## Multi-agent safety

Multiple AI agents work these repos in parallel. Never use `git reset --hard`, `git clean -f`, or any destructive git command without explicit confirmation from the user.

## Confidentiality

Private & Confidential — Property of Lifescope Inc. Do not distribute.
