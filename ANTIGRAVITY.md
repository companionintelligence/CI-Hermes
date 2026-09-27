# ANTIGRAVITY.md — CI-Hermes

## Context

**CI-Hermes** — **App** layer of the Companion Intelligence platform (Lifescope Inc).

Architecture: `CI-Engineering/architecture/architecture.md`
Roadmap: `CI-Engineering/architecture/roadmap.md`

## Purpose

CI marketplace wrapper for the NousResearch Hermes Agent. Provides a web terminal UI (xterm.js) and CI runtime context. Two containers: web (terminal + dashboard proxy) and gateway.

## Stack

- Node.js (web terminal server)
- xterm.js (browser terminal)
- Docker Compose (web + gateway containers)
- CI plugin/skill system

## Commands

```bash
npm install
docker compose up --build
```

Tests (gated by `.github/workflows/ci.yml`, no Docker needed):

```bash
npm test                 # unit (node --test) + shell suites in tests/
cd ci-context/plugins/companionintelligence && python3 -m unittest discover -p '*_test.py'
cd ci-context/plugins/ci-runtime && python3 -m unittest discover -p '*_test.py'
cd patches && python3 -m unittest discover -p '*_test.py'   # needs httpx
```

## Rules

- Package manager: do not switch or mix.
- Destructive git operations (`reset --hard`, `clean -f`) require explicit user confirmation.
- Commits reference CI-Engineering issues.
- All content is **private and confidential** — Property of Lifescope Inc.
