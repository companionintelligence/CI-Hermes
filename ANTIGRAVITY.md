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
# no unit tests — validate via docker compose up
```

## Rules

- Package manager: do not switch or mix.
- Destructive git operations (`reset --hard`, `clean -f`) require explicit user confirmation.
- Commits reference CI-Engineering issues.
- All content is **private and confidential** — Property of Lifescope Inc.
