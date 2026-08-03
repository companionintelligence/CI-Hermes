/**
 * `beforeSend` payload scrubber.
 *
 * CI-Hermes wraps an AI agent that holds a live PTY into the user's own
 * container, so anything on its way to Sentry is treated as hostile until
 * proven otherwise: credentials are redacted, home directories are collapsed to
 * `~` (they leak account names), and oversized strings are truncated so a stray
 * blob can't smuggle terminal scrollback out inside an exception message.
 *
 * Ported from CI-Server's `common/telemetry/scrubEvent.ts` (post adversarial
 * review) so every appliance component redacts identically. Three additions are
 * specific to this wrapper and are covered by `fixtures.cjs`:
 *
 *   1. Terminal frames. The WebSocket carries the user's keystrokes, and
 *      `JSON.parse` failures echo up to ~30 raw bytes of the offending frame
 *      back in the error message.
 *   2. Bare LLM provider keys (`sk-…`). Hermes sources `OPENAI_`/`ANTHROPIC_`/
 *      `GEMINI_` credentials from the Hub bootstrap env; the fleet's rules only
 *      catch them when they appear next to a `key=` style label.
 *   3. Exact-value redaction of known runtime secrets (`registerSecret`). The
 *      terminal WebSocket URL carries `APP_SEED` — an RCE-grade secret — as a
 *      query parameter, and other high-value tokens are minted per boot and so
 *      match no pattern at all.
 */

const SECRET_PATTERNS = [
  /Bearer\s+[A-Za-z0-9\-._~+/]+=*/gi,
  /(?:api[-_ ]?key|token|password|secret|jwt|auth)[\s=:"']+[^\s"',}\]]+/gi,
  /tskey-[A-Za-z0-9-]+/gi,
  // Postgres/Redis/AMQP URLs carry credentials in the authority section.
  /\b[a-z][a-z0-9+.-]*:\/\/[^\s:@/]+:[^\s@/]+@/gi,
  // Bare provider keys: `sk-…`, `sk-proj-…`, `sk-ant-api03-…`. Unlike the
  // labelled rule above these need no `key=` prefix, which is how they arrive
  // when a provider SDK echoes the credential it was handed.
  /\bsk-[A-Za-z0-9_-]{16,}/gi,
];

// Windows first: the macOS pattern also matches the `/Users/<name>` inside
// `C:/Users/<name>`, and replacing that leaves a stranded `C:~/…` with the drive
// letter still attached. The longest-prefix forms have to win.
const HOME_PATH_PATTERNS = [
  /[A-Za-z]:\\Users\\[^\\/\s]+/g, // Windows (backslash)
  /[A-Za-z]:\/Users\/[^/\s]+/g, // Windows (forward-slash)
  /\/Users\/[^/\s]+/g, // macOS
  /\/home\/[^/\s]+/g, // Linux
];

// V8 puts a slice of the offending input straight into the message:
//   Unexpected token 'p', "ssh root@db" is not valid JSON
// Every malformed frame on the terminal socket lands here, and that input is
// whatever the user typed or pasted. Lazy match so only the echoed slice goes.
const JSON_PARSE_SNIPPET = /Unexpected token[\s\S]*?is not valid JSON/gi;
// No `token <value>` shape in the replacement: the labelled-secret rule below
// would match its own output and mangle it into `Unexpected [Filtered]]`.
const JSON_PARSE_REPLACEMENT = "Unexpected token, [Filtered], is not valid JSON";

// `api[-_ ]?key` (not the literals `apikey|api_key`) so the hyphenated header
// forms match too — `x-api-key` is Companion Memory's API-key header, and the
// SDK ships request headers even with sendDefaultPii disabled. `signature`
// covers webhook HMACs (`x-hub-signature-256`, `x-webhook-signature`), which are
// replayable against the verifier and so are credentials in their own right.
// Everything up to `signature` is byte-identical to CI-Server's copy — keep it
// that way and let the Hermes-local terms trail: `hub[-_]user` covers CI-Hub's
// `X-CI-Hub-User`, which carries the household username, and `seed` covers this
// app's own `APP_SEED`.
const SENSITIVE_KEY_PATTERN =
  /password|secret|token|authorization|cookie|jwt|api[-_ ]?key|dsn|pepper|private[-_]?key|signature|hub[-_]user|app[-_]?seed/i;

// Headers whose value is a URL the user navigated from — same query-string
// exposure as request.url, and not caught by SENSITIVE_KEY_PATTERN.
const URL_VALUED_HEADERS = ["referer", "referrer", "location"];

// Breadcrumb `data` keys whose value is a URL. The SDK's http/fetch breadcrumbs
// record the full URL including its query string; on this wrapper that is the
// terminal upgrade URL, which carries the APP_SEED token.
const URL_VALUED_KEYS = new Set(["url", "from", "to"]);

const MAX_STRING_LENGTH = 8000;

/**
 * Literal secret values to redact wherever they appear.
 *
 * Pattern matching cannot see a per-boot random hex string or a bare `APP_SEED`
 * sitting in a header value, so the values themselves are registered at init and
 * struck out by exact match. Short values are ignored: redacting a 4-character
 * string would corrupt unrelated text for no gain.
 */
const MIN_SECRET_LENGTH = 12;
/** Env vars whose *value* is a credential, matched by suffix. */
const SECRET_ENV_KEY_PATTERN = /(?:TOKEN|KEY|SECRET|SEED|PASSWORD|PASSWD|DSN)$/i;

let secretValues = new Set();
let secretPattern = null;

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function rebuildSecretPattern() {
  if (secretValues.size === 0) {
    secretPattern = null;
    return;
  }
  // Longest first so a secret that contains another is replaced whole.
  const alternatives = [...secretValues]
    .sort((a, b) => b.length - a.length)
    .map(escapeRegExp)
    .join("|");
  secretPattern = new RegExp(alternatives, "g");
}

/** Register one literal secret value. No-op for short/absent values. */
function registerSecret(value) {
  if (typeof value !== "string") {
    return;
  }
  const trimmed = value.trim();
  if (trimmed.length < MIN_SECRET_LENGTH || secretValues.has(trimmed)) {
    return;
  }
  secretValues.add(trimmed);
  rebuildSecretPattern();
}

/**
 * Register every credential-looking value in an environment.
 *
 * The wrapper is handed `APP_SEED`, `HUB_MCP_API_KEY`, `CI_SERVER_TOKEN` and the
 * provider keys, and any of them can surface in an error string, a proxied
 * header dump or a spawn environment. Matching on the key name means a new
 * credential is covered the day it is added.
 */
function registerEnvSecrets(env) {
  for (const [key, value] of Object.entries(env || {})) {
    if (SECRET_ENV_KEY_PATTERN.test(key)) {
      registerSecret(value);
    }
  }
}

/** Test seam: forget every registered secret. */
function resetSecrets() {
  secretValues = new Set();
  secretPattern = null;
}

/**
 * Strip query and hash from a URL.
 *
 * Deliberately a plain split rather than `new URL()`: it leaves origin and path
 * exactly as written and cannot throw on a relative path.
 */
function scrubUrl(url) {
  return url.split(/[?#]/)[0] ?? url;
}

function scrubString(value) {
  let scrubbed = value;

  for (const pattern of HOME_PATH_PATTERNS) {
    scrubbed = scrubbed.replace(pattern, "~");
  }

  scrubbed = scrubbed.replace(JSON_PARSE_SNIPPET, JSON_PARSE_REPLACEMENT);

  for (const pattern of SECRET_PATTERNS) {
    scrubbed = scrubbed.replace(pattern, "[Filtered]");
  }

  if (secretPattern) {
    scrubbed = scrubbed.replace(secretPattern, "[Filtered]");
  }

  if (scrubbed.length > MAX_STRING_LENGTH) {
    return `${scrubbed.slice(0, MAX_STRING_LENGTH)}… [truncated]`;
  }

  return scrubbed;
}

function scrubValue(value, depth = 0) {
  // Guard against cyclic/deep structures — a runaway walk in beforeSend would
  // stall the reporting path on every captured error.
  if (depth > 8) {
    return "[Truncated]";
  }

  if (typeof value === "string") {
    return scrubString(value);
  }

  if (Array.isArray(value)) {
    return value.map((entry) => scrubValue(entry, depth + 1));
  }

  if (value && typeof value === "object") {
    const result = {};

    for (const [key, nested] of Object.entries(value)) {
      result[key] = SENSITIVE_KEY_PATTERN.test(key) ? "[Filtered]" : scrubValue(nested, depth + 1);
    }

    return result;
  }

  return value;
}

/**
 * Scrub one breadcrumb in place.
 *
 * `Console` is filtered out at init (see index.cjs) because this wrapper's log
 * lines narrate PTY traffic, but the http/fetch breadcrumbs remain and carry
 * `data.url` **with the query string** — which on the terminal socket is the
 * APP_SEED token.
 */
function scrubBreadcrumb(breadcrumb) {
  if (typeof breadcrumb.message === "string") {
    breadcrumb.message = scrubString(breadcrumb.message);
  }

  if (!breadcrumb.data) {
    return;
  }

  for (const [key, value] of Object.entries(breadcrumb.data)) {
    if (SENSITIVE_KEY_PATTERN.test(key)) {
      // Walking the values alone would skip the key check that scrubValue only
      // applies once it is *inside* an object — so a top-level `data.token`
      // rode out intact. Same shape as the object walk, applied one level up.
      breadcrumb.data[key] = "[Filtered]";
    } else if (typeof value === "string" && URL_VALUED_KEYS.has(key)) {
      breadcrumb.data[key] = scrubUrl(scrubString(value));
    } else {
      breadcrumb.data[key] = scrubValue(value);
    }
  }
}

/** Sentry `beforeSend`: the last thing that runs before a payload leaves. */
function scrubEvent(event) {
  if (!event || typeof event !== "object") {
    return event;
  }

  if (event.message) {
    event.message = scrubString(event.message);
  }

  if (event.exception && event.exception.values) {
    for (const exception of event.exception.values) {
      if (exception.value) {
        exception.value = scrubString(exception.value);
      }

      // Node's stack parser keeps the absolute path in `filename`/`abs_path`,
      // which leaks the account name outside Docker, and `vars` holds captured
      // locals — in this wrapper those are terminal frames and the setup token.
      const frames = (exception.stacktrace && exception.stacktrace.frames) || [];

      for (const frame of frames) {
        if (typeof frame.filename === "string") {
          frame.filename = scrubString(frame.filename);
        }

        if (typeof frame.abs_path === "string") {
          frame.abs_path = scrubString(frame.abs_path);
        }

        if (frame.vars) {
          frame.vars = scrubValue(frame.vars);
        }
      }
    }
  }

  if (event.extra) {
    event.extra = scrubValue(event.extra);
  }

  // `NodeSystemError` (a default integration) parks the raw errno/syscall/
  // address/port — and, when data collection is loosened, `path` — under
  // `contexts.node_system_error`, which nothing else here would touch.
  if (event.contexts) {
    event.contexts = scrubValue(event.contexts);
  }

  // The hostname is the same account-identifying data we collapse `/Users/<name>`
  // to `~` to avoid. `includeServerName: false` in index.cjs stops the SDK
  // setting it; this is the belt-and-braces half.
  delete event.server_name;

  if (event.request) {
    // Query strings and bodies carry the terminal token and proxied dashboard
    // payloads; headers carry the session cookie.
    delete event.request.cookies;
    delete event.request.data;

    if (event.request.query_string) {
      event.request.query_string = "[Filtered]";
    }

    // `request.url` is built from `req.url`, which on a Node server is
    // path+query — so it carries byte-identical content to the query_string we
    // just filtered. Filtering one without the other redacts nothing. On this
    // wrapper the query is `?token=<APP_SEED>` on every terminal upgrade.
    if (typeof event.request.url === "string") {
      event.request.url = scrubUrl(event.request.url);
    }

    if (event.request.headers) {
      const headers = scrubValue(event.request.headers);

      for (const [key, value] of Object.entries(headers)) {
        if (URL_VALUED_HEADERS.includes(key.toLowerCase()) && typeof value === "string") {
          headers[key] = scrubUrl(value);
        }
      }

      event.request.headers = headers;
    }
  }

  for (const breadcrumb of event.breadcrumbs || []) {
    scrubBreadcrumb(breadcrumb);
  }

  return event;
}

module.exports = {
  MAX_STRING_LENGTH,
  registerEnvSecrets,
  registerSecret,
  resetSecrets,
  scrubBreadcrumb,
  scrubEvent,
  scrubString,
  scrubUrl,
  scrubValue,
};
