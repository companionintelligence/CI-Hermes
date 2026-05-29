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
# no unit tests — validate via docker compose up   # test
docker compose build   # build
```

## Security

Only safe behind the CI marketplace app proxy. Do not expose directly to the internet.

## Git discipline

- Never `git reset --hard` or `git clean -f` without user confirmation.
- Commit messages: imperative mood, ≤ 72 chars.
- Reference CI-Engineering issues in PRs (e.g. `Closes companionintelligence/CI-Engineering#32`).

## Confidentiality

Private & Confidential — Property of Lifescope Inc. Do not distribute.
