# Error reporting (Sentry)

The CI-Hermes wrapper can report its own crashes to [Sentry](https://sentry.io).
It is **opt-in and off by default**: with no DSN configured, `@sentry/node` is
never even loaded and the container makes no outbound connection.

This follows the fleet contract set by CI-Server
(`docs/operations/error-reporting.md` there); CI-Import-Tools and
Companion-Planning ship the same env vars and the same redaction rules.

## Scope: what is and is not instrumented

| Process | Instrumented | Why |
|---|---|---|
| `server.cjs` (web container) | **yes** | The wrapper: HTTP proxy, terminal WebSocket, PTY lifecycle. |
| Hermes dashboard (`hermes dashboard`, same container) | no | Upstream NousResearch Python process, started by `entrypoint.sh`. |
| `hermes gateway run` (gateway container) | no | Upstream Python process; instrumenting it means patching the vendored agent. |
| `terminal.html` (browser) | no | See [Why there is no browser SDK](#why-there-is-no-browser-sdk). |

Only wrapper faults are reported. A crash inside Hermes itself surfaces the way
it always has — in the container log and the terminal.

## Privacy posture

This container runs an AI agent with a live PTY into the user's data, so
reporting is deliberately narrower than a default Sentry install:

| Setting | Value | Why |
|---|---|---|
| `sendDefaultPii` | `false` | No IPs, cookies, or request bodies. |
| `tracesSampleRate` | `0` | Errors only; traces would ship request shapes we have no consent to collect. |
| `profilesSampleRate` | `0` | — |
| Session replay | not installed | — |
| `includeServerName` | `false` | The hostname identifies the household like a home path does. |
| `includeLocalVariables` | `false` | Frame locals in this process are terminal frames and tokens. |
| `beforeSend` | scrubber | `telemetry/scrub.cjs`; fails closed (drops the event) if it throws. |

Four default integrations are removed at init (`telemetry/index.cjs`):

- **`Console`** — every console line in `server.cjs` narrates PTY/WebSocket
  traffic (`Error processing terminal input: …`), so console breadcrumbs are a
  direct path from the user's keystrokes into an event.
- **`LocalVariables` / `LocalVariablesAsync`** — captured locals here are the
  WebSocket frame, the PTY output buffer and `SETUP_TOKEN`. Off by default in the
  SDK today; dropped outright so a future default flip cannot turn them on.
- **`OnUncaughtException` / `OnUnhandledRejection`** — the wrapper has its own
  handlers that log and **keep serving**. The SDK's would report the same crash
  twice and can exit the process; reporting is not allowed to change behaviour.
- **`ProcessSession`** — release-health sessions phone home on start and exit
  even when nothing has gone wrong. Opt-in error reporting should mean the
  appliance talks to Sentry when it has a crash to report, and not otherwise.

## Kill switches

Two switches disable reporting even when a DSN is baked into an image (which is
how a Hub-installed app receives one), so an operator can turn it off without a
rebuild:

| Variable | Effect |
|---|---|
| `CI_TELEMETRY=off` | Explicit opt-out (also `false`, `0`, `no`, `disabled`). |
| `CI_LOCAL_ONLY=true` | Local-only mode means zero phone-home (also `1`, `yes`, `on`, `enabled`). |

`CI_LOCAL_ONLY` takes precedence over `CI_TELEMETRY`, which takes precedence over
the DSN. The resolved reason is reported as `local-only`, `opt-out` or `no-dsn`.

Because the only Sentry SDK here runs in the container, the marketplace "Share
crash reports" toggle — which sets `CI_TELEMETRY` on the container — applies
directly, with no build-time consent problem to solve.

## Checking the gate at runtime

```bash
curl -s http://localhost:18790/__ci_telemetry/config
# {"enabled":false,"reason":"no-dsn"}
# {"enabled":true,"reporting":true,"environment":"production","release":"ci-hermes-web@v2026.7.20"}
```

Never returns the DSN, and never anything user-derived. `enabled` is the
operator's decision; `reporting` is what the process is actually doing (they
differ only if the SDK could not be loaded).

The path is deliberately **not** the fleet's `/api/config/telemetry`: `/api/*` on
this wrapper belongs to the upstream Hermes dashboard it proxies, so an endpoint
there would shadow whatever upstream adds under that path. `/__ci_*` is this
repo's existing namespace for wrapper-owned routes (see `/__ci_memory/*`).

## What gets scrubbed

`telemetry/scrub.cjs` implements the fleet's rules:

- Bearer tokens, `api_key=` / `password:` / `token:` style pairs, Tailscale
  `tskey-…`, and credentials in connection URLs → `[Filtered]`
- Home directories (`/Users/<name>`, `/home/<name>`, `C:\Users\<name>`) → `~`,
  since they leak the account name. Windows patterns run **before** the macOS one
  or `C:/Users/<name>` leaves a stranded `C:~/…`
- Object, header and breadcrumb-data keys matching
  `password|secret|token|authorization|cookie|jwt|api[-_ ]?key|dsn|pepper|private_key|hub_user|app_seed`
  → `[Filtered]`. The hyphenated form matters: `sendDefaultPii: false` does **not**
  stop request headers, so this regex is the only guard on `x-api-key` and on
  CI-Hub's `X-CI-Hub-User` (the household username)
- Request cookies and bodies dropped; **query strings removed from
  `request.query_string`, from `request.url`, and from the `referer` /
  `referrer` / `location` headers** — the SDK builds `request.url` from
  `req.url`, which on a Node server is path+query, so filtering only
  `query_string` redacts nothing. On this wrapper that query is
  `?token=<APP_SEED>` on every terminal WebSocket upgrade
- Breadcrumbs: `message`, every `data` value, and `data.url` / `.from` / `.to`
  treated as URLs. The wrapper's own Hub call carries
  `?clientHost=<the household's public host>`
- Stack frame `filename` / `abs_path` (home collapsed only — Sentry groups issues
  on `filename`, so redacting the body would destroy grouping) and captured `vars`
- `server_name` removed, and `includeServerName: false` set at init
- `contexts`, where the `NodeSystemError` integration parks raw
  `syscall`/`path`/`address` details
- Strings over 8 KB truncated, so terminal scrollback can't ride out inside an
  exception message

Three rules are specific to this app:

- **Terminal frames.** V8 echoes the first ~10 bytes of the offending input in
  `JSON.parse` failures (`Unexpected token 's', "ssh deploy"... is not valid
  JSON`), and on the terminal socket that input is the user's keystrokes. The
  message shape is redacted, *and* the handler in `server.cjs` reports a
  synthesised error instead of the original — never constructing the payload is
  the guarantee that does not depend on V8's wording.
- **Bare provider keys** (`sk-…`, `sk-proj-…`, `sk-ant-…`). Hermes sources
  `OPENAI_`/`ANTHROPIC_`/`GEMINI_` credentials from the Hub bootstrap env; the
  fleet's rules only catch those next to a `key=` label.
- **Exact-value redaction.** `APP_SEED` is an RCE-grade secret (it gates the
  terminal WebSocket) and the memory-gate action token is minted per boot, so no
  pattern can recognise it. Every credential-shaped env value (`*_TOKEN`,
  `*_KEY`, `*_SECRET`, `*_SEED`, `*_PASSWORD`, `*_DSN`) plus the per-boot token
  is registered at init and struck out by literal match.

### Why there is no browser SDK

`terminal.html` is served as a single static file with no bundler, so the
build-time `VITE_SENTRY_DSN` pattern the rest of the fleet uses does not apply.
It is also the wrong place for it: that page *is* an xterm.js buffer of the
user's shell session, and a browser SDK would sit inside the keystroke and
render path with breadcrumbs enabled. Wrapper-side reporting covers the same
faults from a position where the payload can actually be controlled. If browser
reporting is ever added, it must consult `/__ci_telemetry/config` first and fail
closed, exactly as CI-Server's web bundle does.

## Sentry project

Reports go to a project named after the marketplace app id: **`ci-hermes`** in
the `companion-intelligence` org. The project is **not created yet** — the org
sets `allowMemberProjectCreation: false`, so an owner has to create it and hand
back the DSN.

Every event carries a `component` tag (`ci-hermes-web`) and, when
`CI_HERMES_VERSION` is set, a `deployment_version` tag.

```bash
sentry issue list companion-intelligence/ci-hermes --query "is:unresolved"
```

## Enabling it

```bash
# .env (local) — or the app's environment on a Hub install
SENTRY_DSN=https://<key>@o<org>.ingest.us.sentry.io/<id>
SENTRY_ENV=production
CI_HERMES_VERSION=v2026.7.20
```

Turning it off again, without rebuilding:

```bash
CI_TELEMETRY=off docker compose up -d
```

## Verifying

```bash
npm test                                   # gate, scrubber and integration-filter suites
curl -s localhost:18790/__ci_telemetry/config
```

To confirm reporting is genuinely inert without a DSN, start the container with
no `SENTRY_DSN` and check that nothing resolves `ingest.sentry.io`. The suite
asserts the stronger form: with no DSN the `@sentry/node` module is never even
placed in `require.cache`.

## Where it hooks in

| Path | Role |
|---|---|
| `telemetry/settings.cjs` | Resolves the opt-in gate from env |
| `telemetry/scrub.cjs` | `beforeSend` scrubber |
| `telemetry/fixtures.cjs` | Redaction cases shared with the rest of the fleet (drift guard) |
| `telemetry/index.cjs` | `Sentry.init`, capture helper, bounded flush |
| `server.cjs` (top of file) | `telemetry.init()` — must stay above `require("http")` |
| `server.cjs` crash handlers | Capture `uncaughtException` / `unhandledRejection`, without changing the "log and keep serving" behaviour |
| `server.cjs` SIGTERM | Bounded 2 s flush; never blocks the stop grace period |
| `server.cjs` `/__ci_telemetry/config` | Runtime gate status |

## Not wired up yet

- **The `ci-hermes` Sentry project and its DSN.** Nothing is sent until an owner
  creates it.
- **Release / source-map upload in CI.** `docker-publish.yml` does not pass
  `SENTRY_RELEASE`; releases fall back to `ci-hermes-web@<CI_HERMES_VERSION>`.
- **The upstream Hermes processes** (dashboard, gateway) — see the scope table.
