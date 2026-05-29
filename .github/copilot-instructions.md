# GitHub Copilot Instructions — CI-Hermes

You are working in **CI-Hermes**, the **App** component of the **Companion Intelligence** platform — a private, local-first digital memory and AI appliance system owned by Lifescope Inc.

## Platform architecture

```
Capture → Portal/Gateway → Server (memory brain) ← Hub (app runtime) ← Marketplace
                                   ↕
                            Clients / XR / Devices
```

Full architecture and ADRs live in `CI-Engineering/architecture/`.

## This repo

CI marketplace wrapper for the NousResearch Hermes Agent. Provides a web terminal UI (xterm.js) and CI runtime context. Two containers: web (terminal + dashboard proxy) and gateway.

## Tech stack

- Node.js (web terminal server)
- xterm.js (browser terminal)
- Docker Compose (web + gateway containers)
- CI plugin/skill system

## Development

```bash
npm install   # install
# no unit tests — validate via docker compose up   # test
```

## Security

Only safe behind the CI marketplace app proxy. Do not expose directly to the internet.

## Conventions

- Do not mix package managers.
- Keep PRs small and linked to CI-Engineering issues.
- Multiple agents may work this codebase simultaneously — never use destructive git operations.
- All code is **private and confidential** — do not surface or transmit source beyond this session.
