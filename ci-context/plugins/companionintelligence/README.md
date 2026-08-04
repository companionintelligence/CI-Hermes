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

The URL it offers by default is `http://127.0.0.1:8642`, which is correct only when
Hermes runs on the hub host itself. See [Which URL do I use?](#which-url-do-i-use) for
the address to give it otherwise.

That is the whole activation — `memory.provider` is what Hermes reads when it starts a
session. Confirm with `hermes memory status`.

`hermes plugins list` and the `/plugins` page will still show this plugin as **not
enabled**, which looks like a missed step but is not one. That registry is the general
plugin loader, and Hermes deliberately routes memory providers away from it (it coerces
them to `kind: exclusive`, because the general plugin context has no
`register_memory_provider`). Enabling it there activates nothing extra, and prompts you
to grant a built-in tool override — a privileged capability this plugin never uses.

> `hermes memory setup` is a command-line command, not a chat message. Typed at the
> chat prompt (`❯`), Hermes will simply answer it like a question and nothing gets
> configured.

### Upgrading

Re-run the same commands with the new version — including the `rm -rf`, for the
reason given above.

Your settings survive: `hermes memory setup` writes them to `$HERMES_HOME/.env` and
`$HERMES_HOME/companionintelligence/config.json`, both of which live **outside** the
plugin directory you are replacing.

## Which URL do I use?

Companion Memory runs as an app on your Companion Hub, and a hub can answer on more than
one address at the same time. Which one you give the wizard depends on where Hermes runs,
not on which address is the "real" one. The plugin calls the server from the Hermes
process rather than from a browser, so no origin or CORS restriction applies: any address
the Hermes machine can route to will work.

The app's exposure is set in the hub under **App → Settings**. Each setting produces a
different address:

| Exposure | Address shape | Reachable from |
| --- | --- | --- |
| Local network (default) | `http://ci-memory.ci.lan` — or `http://<hub-ip>:8642` if Traefik routing is not set up | Devices on the hub's LAN |
| Private VPN (Tailscale) | `https://<hub>.<tailnet>.ts.net:8642` | Any device signed into your tailnet |
| Public (**Expose app**) | `https://<the domain you configured>` | Anywhere |

`ci.lan` is the default local domain and can be changed in **Settings → General**; `8642`
is Companion Memory's app port, and the reason the wizard's default is `127.0.0.1:8642`.

This value is written to `config.json` once and never re-resolved, so it does not follow
you between networks. A Hermes install that always runs on the hub's LAN is served by the
local address, and its traffic never leaves your network. A Hermes install on a machine
that moves — a laptop that leaves the house — keeps working only on an address reachable
from wherever it goes, which means joining the tailnet or exposing the app publicly;
exposing it puts the memory server on the internet, where its API key is the only thing
guarding it. The three forms differ in reach and in what they ask of you, not in what the
plugin can do with them.

### If the wizard refuses to save

Because it saves nothing on a failed health check, a wrong address ends as a rejected
setup rather than a broken install. Two causes are common:

- **A missing scheme.** The wizard prepends `http://` to anything typed without one, so
  `hub.tailnet.ts.net` becomes `http://hub.tailnet.ts.net` and fails against an
  HTTPS-only address. Type `https://` yourself for the VPN and public forms.
- **The default.** Pressing Enter accepts `http://127.0.0.1:8642`, which cannot work
  unless Hermes is running on the hub host.
- **A `403` whose body is an HTML page.** Companion Memory answers in JSON, so an HTML
  error came from a CDN or proxy in front of it and the server never saw the request —
  your key is not the problem. The wizard says so when it sees one. Use the app's LAN or
  VPN address instead of its public URL, or allow this plugin through at the edge (it
  identifies itself; see below).

A timeout or a refused connection points at the address; a `401` points at the key.

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
`false` to disable that behaviour.

To stop the integration entirely without uninstalling, run `hermes memory off`, which
clears `memory.provider` in `config.yaml`. That alone is enough — the `/plugins` page
does not gate this plugin (see above). Setting every flag above to `false` also works. (`CI_SERVER_ENABLED` is **not** an
off-switch here — it is read only by the packaged Companion Intelligence appliance,
not by this plugin, so on a stock install it has no effect.)

## What it talks to

`GET /api/health`, `GET /api/memory/context`, `POST /api/memory/recall`,
`POST /api/memory/write`, `POST /api/memory/turn`, and the agent intents endpoints.
No third-party services.

Every request is sent with `User-Agent: companionintelligence-hermes-memory/<version>`,
so the plugin is identifiable in an access log and can be allowed through a proxy by
name. This matters more than it sounds: a bot rule that rejects the requests instead has
no visible symptom, because capture failures are swallowed rather than allowed to break a
session — setup passes and memory just never accumulates.

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
