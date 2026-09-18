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

# Build for production
docker compose build
```

## Package manager

**npm** — use exclusively; do not mix with npm/yarn/pnpm/bun unless the repo explicitly requires it.

## Cross-repo connections

- Receives MCP calls from CI-Hub via marketplace app proxy
- ci-context plugin provides CI-Server awareness to Hermes
- CI skill wired into Hermes plugin/skill surfaces

## Security

Only safe behind the CI marketplace app proxy. Do not expose directly to the internet.

## Multi-agent safety

Multiple AI agents work these repos in parallel. Never use `git reset --hard`, `git clean -f`, or any destructive git command without explicit confirmation from the user.

## Confidentiality

Private & Confidential — Property of Lifescope Inc. Do not distribute.
