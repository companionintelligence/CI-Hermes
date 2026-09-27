# AGENTS.md — CI-Hermes

## Platform context

CI-Hermes is the **App** layer component of the Companion Intelligence platform — a private, local-first digital memory system.

Full architecture: `CI-Engineering/architecture/architecture.md`

## Repo summary

CI marketplace wrapper for the NousResearch Hermes Agent. Provides a web terminal UI (xterm.js) and CI runtime context. Two containers: web (terminal + dashboard proxy) and gateway.

## Stack

- Node.js (web terminal server)
- xterm.js (browser terminal)
- Docker Compose (web + gateway containers)
- CI plugin/skill system

## Setup & commands

```bash
npm install   # install
docker compose up --build   # dev
docker compose build   # build
```

Tests (gated by `.github/workflows/ci.yml`, no Docker needed):

```bash
npm test                 # unit (node --test) + shell suites in tests/
cd ci-context/plugins/companionintelligence && python3 -m unittest discover -p '*_test.py'
cd ci-context/plugins/ci-runtime && python3 -m unittest discover -p '*_test.py'
cd patches && python3 -m unittest discover -p '*_test.py'   # needs httpx
```

## Security

Only safe behind the CI marketplace app proxy. Do not expose directly to the internet.

## Git discipline

- Never `git reset --hard` or `git clean -f` without user confirmation.
- Commit messages: imperative mood, ≤ 72 chars.
- Reference CI-Engineering issues in PRs (e.g. `Closes companionintelligence/CI-Engineering#32`).

## Confidentiality

Private & Confidential — Property of Lifescope Inc. Do not distribute.
