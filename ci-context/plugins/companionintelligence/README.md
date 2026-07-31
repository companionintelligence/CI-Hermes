# Companion Intelligence memory for Hermes

Makes a self-hosted [Companion Memory](https://docs.ci.computer) server Hermes'
memory provider: conversations are ingested passively as they happen, and relevant
context is injected into later sessions automatically.

You do not need the packaged Companion Intelligence Hermes app to use this. A stock
Hermes install is enough.

## Requirements

- Hermes Agent
- A reachable Companion Memory server
- A Companion Memory API key with the `memory` scope, minted in the server's web UI
  under **Settings → API Keys**
- Python 3 — no other dependencies. The plugin declares `pip_dependencies: []` and
  uses only the standard library.

## Install

Hermes discovers memory providers by scanning `$HERMES_HOME/plugins/` (by default
`~/.hermes/plugins/`) for a directory containing a `plugin.yaml`. It has no plugin
registry, and it never looks in `site-packages` — so installing means putting this
directory there:

```sh
rm -rf ~/.hermes/plugins/companionintelligence
mkdir -p ~/.hermes/plugins/companionintelligence
curl -fL https://registry.npmjs.org/@companionintelligence/hermes-memory/-/hermes-memory-<version>.tgz \
  | tar -xz -C ~/.hermes/plugins/companionintelligence --strip-components=1
```

Replace `<version>` with a published version — `2026.8.1`, for example. The list of
published versions is on
[the package page](https://www.npmjs.com/package/@companionintelligence/hermes-memory?activeTab=versions).
Not every appliance release has a matching plugin version: releases that do not
change the plugin do not publish one.

Three details in those commands are deliberate:

- **`rm -rf` first.** `tar -x` overwrites files but never removes them, so extracting
  over an old install leaves behind modules that a later version deleted or renamed
  — along with their stale `__pycache__` — in a directory Python imports from. Start
  clean. Your credentials are not in this directory (see below), so this is safe.
- **`curl -fL`, not `curl -L`.** Without `-f`, curl exits 0 on a 404 and pipes the
  registry's JSON error page into `tar`, which then fails with a confusing "not in
  gzip format" instead of "that version does not exist".
- **`--strip-components=1`** drops the `package/` prefix the archive carries, so the
  files land at the top level of the plugin directory, which is where the loader
  looks.

The archive is hosted on the npm registry purely as versioned tarball hosting; you do
not need Node or npm installed, and nothing is installed into a Node project.

Then configure it, from a terminal:

```sh
hermes memory setup
```

Pick `companionintelligence` if you are asked, and enter your server URL and API key.
The wizard runs a connection test against `GET /api/health` and **saves nothing if it
fails**. On success it writes the key to `.env`, the URL to
`companionintelligence/config.json`, and sets `memory.provider` in `config.yaml`.

Finally, open the Hermes **`/plugins`** page and enable `companionintelligence`.

> `hermes memory setup` is a command-line command, not a chat message. Typed at the
> chat prompt (`❯`), Hermes will simply answer it like a question and nothing gets
> configured.

### Upgrading

Re-run the same commands with the new version — including the `rm -rf`, for the
reason given above.

Your settings survive: `hermes memory setup` writes them to `$HERMES_HOME/.env` and
`$HERMES_HOME/companionintelligence/config.json`, both of which live **outside** the
plugin directory you are replacing.

## Configuration

`hermes memory setup` writes these for you; they are listed for the case where you
would rather set them directly.

| Setting | Where | Meaning |
| --- | --- | --- |
| `CI_SERVER_URL` | `.env`, or `url` in `config.json` | Companion Memory base URL. A trailing `/api/mcp` is stripped, so either form works. |
| `CI_SERVER_TOKEN` | `.env`, or `token` in `config.json` | API key, sent as `x-api-key`. |
| `memory.provider` | `config.yaml` | Set to `companionintelligence` to select this provider. |

`config.json` values take precedence over the environment. Capture and recall can be
narrowed with environment variables, all enabled by default:
`CI_MEMORY_CONTEXT_ENABLED`, `CI_MEMORY_RECALL_ENABLED`, `CI_MEMORY_TURN_ENABLED`,
`CI_MEMORY_WRITE_ENABLED`, `CI_INTENTS_ENABLED`, `CI_INTENT_TOOLS_ENABLED`. Set any to
`false` to disable that behaviour. `CI_SERVER_ENABLED=false` turns the whole
integration off without removing it.

## What it talks to

`GET /api/health`, `GET /api/memory/context`, `POST /api/memory/recall`,
`POST /api/memory/write`, `POST /api/memory/turn`, and the agent intents endpoints.
No third-party services.

## Uninstall

Removing the plugin directory is not enough — `hermes memory setup` wrote settings in
two other places, and one of them holds your API key:

```sh
rm -rf ~/.hermes/plugins/companionintelligence   # the plugin itself
rm -rf ~/.hermes/companionintelligence           # the saved server URL
```

Then edit `~/.hermes/config.yaml` to clear `memory.provider` and drop
`companionintelligence` from `plugins.enabled`, and **remove `CI_SERVER_TOKEN` from
`~/.hermes/.env`** — otherwise a live Companion Memory API key stays on disk after you
believe you have uninstalled. Revoke it in the server's web UI if you no longer need
it.

Your data on the Companion Memory server is untouched by any of this.

## A note on `package.json`

The archive contains a `package.json`. It is packaging metadata for the registry that
hosts the tarball, and it is inert to Hermes — the loader reads `plugin.yaml`. You can
delete it after extracting; nothing depends on it.

## License

MIT
