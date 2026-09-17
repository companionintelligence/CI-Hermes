"use strict";

// The Hub handout env file ($HERMES_HOME/.env.hub-bootstrap) as server.cjs merges it
// into each terminal session. The same rule as hub-env.sh, which the web entrypoint,
// the gateway and start-hermes.sh use; tests/hub-env.test.cjs runs both on one file
// and requires the same result. The reasoning lives in hub-env.sh.

const fs = require("fs");

const HUB_ENV_ALLOWED_PREFIXES = [
  "OPENAI_",
  "HERMES_",
  "CUSTOM_",
  "ANTHROPIC_",
  "GEMINI_",
  "GOOGLE_",
  "OLLAMA_",
];

// config.yaml model.default is authoritative (reconcile-hub-config.py).
const HUB_ENV_CONFIG_OWNED_KEYS = [
  "HERMES_INFERENCE_MODEL",
  "HERMES_MODEL",
  "OPENAI_MODEL",
];

// For the Hub's own endpoint config.yaml also owns the endpoint.
const HUB_ENV_LOCAL_ENDPOINT_KEYS = [
  "CUSTOM_BASE_URL",
  "CUSTOM_API_KEY",
  "OPENAI_BASE_URL",
  "OPENAI_API_BASE",
  "OPENAI_API_KEY",
];

const LINE_RE = /^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s;

function unquote(value) {
  const dq = /^"(.*)"$/s.exec(value);
  if (dq) return dq[1];
  const sq = /^'(.*)'$/s.exec(value);
  if (sq) return sq[1];
  return value;
}

/**
 * Parse handout text into what a loader does with it: `set` the {key: value} to
 * export, and `unset` the keys config.yaml owns, which must not survive from an
 * inherited environment either.
 */
function parseHubEnv(text) {
  const entries = [];
  let isLocal = false;
  for (let line of String(text).split("\n")) {
    if (line.endsWith("\r")) line = line.slice(0, -1);
    if (!line || /^\s*#/.test(line)) continue;
    const m = LINE_RE.exec(line);
    if (!m) continue;
    const key = m[1];
    const value = unquote(m[2]);
    if (key === "HERMES_OPENAI_API_KEY") isLocal = value === "ollama";
    entries.push([key, value]);
  }
  const unset = [...HUB_ENV_CONFIG_OWNED_KEYS, ...(isLocal ? HUB_ENV_LOCAL_ENDPOINT_KEYS : [])];
  const set = {};
  for (const [key, value] of entries) {
    if (!HUB_ENV_ALLOWED_PREFIXES.some((prefix) => key.startsWith(prefix))) continue;
    if (unset.includes(key)) continue;
    set[key] = value;
  }
  return { set, unset };
}

/**
 * `baseEnv` with the handout file applied, as load_hub_env_file in hub-env.sh would
 * leave a shell. A missing file changes nothing; an unreadable one is reported and
 * changes nothing.
 */
function applyHubBootstrapEnv(baseEnv, file, warn = console.warn) {
  const env = { ...baseEnv };
  let parsed;
  try {
    if (!fs.existsSync(file)) return env;
    parsed = parseHubEnv(fs.readFileSync(file, "utf8"));
  } catch (e) {
    warn(`Failed to read ${file}: ${e.message}`);
    return env;
  }
  for (const key of parsed.unset) delete env[key];
  return Object.assign(env, parsed.set);
}

module.exports = {
  HUB_ENV_ALLOWED_PREFIXES,
  HUB_ENV_CONFIG_OWNED_KEYS,
  HUB_ENV_LOCAL_ENDPOINT_KEYS,
  parseHubEnv,
  applyHubBootstrapEnv,
};
