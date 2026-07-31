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
mkdir -p ~/.hermes/plugins/companionintelligence
curl -L https://registry.npmjs.org/@companionintelligence/hermes-memory/-/hermes-memory-<version>.tgz \
  | tar -xz -C ~/.hermes/plugins/companionintelligence --strip-components=1
```

`--strip-components=1` drops the `package/` prefix the archive carries, so the files
land at the top level of the plugin directory, which is where the loader expects
them. The archive is hosted on the npm registry purely as versioned tarball hosting;
you do not need Node or npm installed, and nothing is installed into a Node project.

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

Re-run the same two commands with the new version. Your `config.json` is not part of
the archive, so extracting over an existing install cannot overwrite it.

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

```sh
rm -rf ~/.hermes/plugins/companionintelligence
```

Then clear `memory.provider` in `config.yaml`. Your data on the Companion Memory
server is untouched.

## A note on `package.json`

The archive contains a `package.json`. It is packaging metadata for the registry that
hosts the tarball, and it is inert to Hermes — the loader reads `plugin.yaml`. You can
delete it after extracting; nothing depends on it.

## License

MIT
