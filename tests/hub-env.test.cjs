const { describe, test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const hubEnv = require("../hub-env.cjs");

const ROOT = path.join(__dirname, "..");
const HUB_ENV_SH = path.join(ROOT, "hub-env.sh");

// ---------------------------------------------------------------------------
// The web container (entrypoint.sh), the gateway (gateway-entrypoint.sh) and each
// terminal session (start-hermes.sh) load the Hub handout through hub-env.sh;
// server.cjs merges it into a session's env through hub-env.cjs. They used to be four
// separate parsers that disagreed — the gateway skipped CUSTOM_*, the web entrypoint
// exported everything by `source`ing the file — so one handout could leave the two
// containers on different endpoints. These tests hold the two implementations to one
// rule by running both on the same file and the same inherited environment.
// ---------------------------------------------------------------------------

function withHandout(text, fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "hub-env-"));
  const file = path.join(dir, ".env.hub-bootstrap");
  fs.writeFileSync(file, text);
  try {
    return fn(file, dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

/** The env a bash process has after `load_hub_env_file`, starting from `base`. */
function bashLoad(file, base) {
  const script = `set -euo pipefail; source "$1"; load_hub_env_file "$2"; env -0`;
  const result = spawnSync("bash", ["-c", script, "_", HUB_ENV_SH, file], {
    env: { PATH: process.env.PATH, ...base },
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  const env = {};
  for (const entry of result.stdout.split("\0")) {
    const eq = entry.indexOf("=");
    if (eq > 0) env[entry.slice(0, eq)] = entry.slice(eq + 1);
  }
  return env;
}

/** Only the keys a handout can touch, so bash's own variables don't enter the comparison. */
function handoutKeys(env) {
  const prefixes = hubEnv.HUB_ENV_ALLOWED_PREFIXES;
  return Object.fromEntries(
    Object.entries(env)
      .filter(([k]) => prefixes.some((p) => k.startsWith(p)) || k === "UNRELATED")
      .sort(([a], [b]) => a.localeCompare(b)),
  );
}

function bothLoaders(text, base = {}) {
  return withHandout(text, (file) => {
    const shell = handoutKeys(bashLoad(file, base));
    const node = handoutKeys(hubEnv.applyHubBootstrapEnv(base, file));
    assert.deepEqual(node, shell, "hub-env.cjs and hub-env.sh disagree");
    return node;
  });
}

const POOL = "http://ci-os-hub:5002/api/inference/pool/v1";

// What v2026.8.9 wrote for a local handout: every override config.yaml now owns.
const OLD_LOCAL_FILE = [
  `CUSTOM_BASE_URL=${POOL}`,
  `HERMES_OPENAI_BASE_URL=${POOL}`,
  "CUSTOM_API_KEY=ollama",
  "HERMES_OPENAI_API_KEY=ollama",
  "CI_INFERENCE_BACKEND=ollama",
  "OPENAI_MODEL=qwen3-coder:30b",
  "HERMES_INFERENCE_MODEL=qwen3-coder:30b",
  "HERMES_DEFAULT_MODEL=qwen3-coder:30b",
  "OLLAMA_HOST=http://ci-os-hub:5002/api/inference/pool",
  "HERMES_NUM_CTX=65536",
  "",
].join("\n");

describe("hub handout loaders", () => {
  test("a local handout exports nothing that outranks config.yaml", () => {
    const env = bothLoaders(OLD_LOCAL_FILE);
    for (const key of [
      "CUSTOM_BASE_URL",
      "CUSTOM_API_KEY",
      "HERMES_INFERENCE_MODEL",
      "OPENAI_MODEL",
      "OPENAI_BASE_URL",
      "OPENAI_API_KEY",
    ]) {
      assert.equal(env[key], undefined, `${key} must not be exported for the Hub endpoint`);
    }
    assert.equal(env.HERMES_DEFAULT_MODEL, "qwen3-coder:30b");
    assert.equal(env.HERMES_OPENAI_BASE_URL, POOL);
    assert.equal(env.OLLAMA_HOST, "http://ci-os-hub:5002/api/inference/pool");
  });

  test("a stale override inherited from before the handout changed is removed", () => {
    // server.cjs's own env after a cloud handout, then a local one: the session must
    // not keep the cloud endpoint over config.yaml.
    const env = bothLoaders(OLD_LOCAL_FILE, {
      CUSTOM_BASE_URL: "https://api.openai.com/v1",
      OPENAI_API_KEY: "sk-stale",
      HERMES_INFERENCE_MODEL: "gpt-4o",
      UNRELATED: "kept",
    });
    assert.equal(env.CUSTOM_BASE_URL, undefined);
    assert.equal(env.OPENAI_API_KEY, undefined);
    assert.equal(env.HERMES_INFERENCE_MODEL, undefined);
    assert.equal(env.UNRELATED, "kept");
  });

  test("a cloud handout keeps its endpoint in env, but never a model override", () => {
    const env = bothLoaders(
      [
        "CUSTOM_BASE_URL=https://api.openai.com/v1",
        "OPENAI_API_BASE=https://api.openai.com/v1",
        "OPENAI_BASE_URL=https://api.openai.com/v1",
        "HERMES_OPENAI_BASE_URL=https://api.openai.com/v1",
        "CUSTOM_API_KEY=sk-cloud",
        "OPENAI_API_KEY=sk-cloud",
        "HERMES_OPENAI_API_KEY=sk-cloud",
        "OPENAI_MODEL=gpt-4o",
        "HERMES_INFERENCE_MODEL=gpt-4o",
        "HERMES_DEFAULT_MODEL=gpt-4o",
        "",
      ].join("\n"),
      { HERMES_MODEL: "stale-model" },
    );
    assert.equal(env.CUSTOM_BASE_URL, "https://api.openai.com/v1");
    assert.equal(env.OPENAI_API_KEY, "sk-cloud");
    assert.equal(env.HERMES_INFERENCE_MODEL, undefined);
    assert.equal(env.OPENAI_MODEL, undefined);
    assert.equal(env.HERMES_MODEL, undefined);
  });

  test("the endpoint rule reads the key wherever it sits in the file", () => {
    const env = bothLoaders(`CUSTOM_BASE_URL=${POOL}\nHERMES_OPENAI_BASE_URL=${POOL}\nHERMES_OPENAI_API_KEY="ollama"\n`);
    assert.equal(env.CUSTOM_BASE_URL, undefined);
  });

  test("values are data: nothing in the file is executed", () => {
    withHandout("", (_file, dir) => {
      const marker = path.join(dir, "executed");
      const text = [
        `HERMES_EMBEDDINGS_MODEL=$(touch ${marker})`,
        `OLLAMA_HOST=\`touch ${marker}\``,
        `HERMES_DEFAULT_MODEL=a b; touch ${marker}`,
        "",
      ].join("\n");
      const env = bothLoaders(text);
      assert.equal(fs.existsSync(marker), false, "a value ran as shell");
      assert.equal(env.HERMES_EMBEDDINGS_MODEL, `$(touch ${marker})`);
      assert.equal(env.HERMES_DEFAULT_MODEL, `a b; touch ${marker}`);
    });
  });

  test("parsing edge cases agree: CRLF, quotes, comments, junk, unlisted prefixes", () => {
    const env = bothLoaders(
      [
        "# comment",
        "  HERMES_DEFAULT_MODEL='qwen3.5:9b'\r",
        'HERMES_NUM_CTX="65536"',
        "HERMES_EMBEDDINGS_MODEL=\"unbalanced",
        "not a line",
        "=nokey",
        "CI_CLOUD_OPENAI_API_KEY=sk-not-exported",
        "HERMES_OPENAI_API_KEY=ollama",
        "HERMES_OPENAI_API_KEY=sk-later-wins",
        "CUSTOM_BASE_URL=https://example.test/v1",
        "",
      ].join("\n"),
    );
    assert.equal(env.HERMES_DEFAULT_MODEL, "qwen3.5:9b");
    assert.equal(env.HERMES_NUM_CTX, "65536");
    assert.equal(env.HERMES_EMBEDDINGS_MODEL, '"unbalanced');
    assert.equal(env.CI_CLOUD_OPENAI_API_KEY, undefined);
    // The last HERMES_OPENAI_API_KEY is a real credential, so this is not the Hub endpoint.
    assert.equal(env.CUSTOM_BASE_URL, "https://example.test/v1");
  });

  test("a missing file changes nothing", () => {
    const base = { CUSTOM_BASE_URL: "http://operator-set/v1" };
    assert.deepEqual(hubEnv.applyHubBootstrapEnv(base, "/does/not/exist"), base);
    const shell = handoutKeys(bashLoad("/does/not/exist", base));
    assert.deepEqual(shell, base);
  });
});

describe("server.cjs", () => {
  test("spawns terminal sessions through hub-env.cjs, not a parser of its own", () => {
    const source = fs.readFileSync(path.join(ROOT, "server.cjs"), "utf8");
    assert.match(source, /require\("\.\/hub-env\.cjs"\)/);
    assert.match(source, /hubEnv\.applyHubBootstrapEnv\(process\.env, HUB_ENV_FILE\)/);
    assert.doesNotMatch(source, /HUB_ENV_PREFIXES/);
  });

  test("the entrypoints and the terminal all load through hub-env.sh", () => {
    for (const script of ["entrypoint.sh", "gateway-entrypoint.sh", "start-hermes.sh"]) {
      const source = fs.readFileSync(path.join(ROOT, script), "utf8");
      assert.match(source, /hub-env\.sh"?\n/, `${script} does not source hub-env.sh`);
      assert.match(source, /load_hub_env_file /, `${script} does not load the handout`);
      assert.doesNotMatch(source, /set -a/, `${script} exports the handout wholesale`);
      assert.doesNotMatch(source, /^\s*(is_allowed_key|load_hub_env_file)\(\)/m, `${script} parses the handout itself`);
    }
  });

  test("the image ships the shared loaders and the reconciler", () => {
    const dockerfile = fs.readFileSync(path.join(ROOT, "Dockerfile"), "utf8");
    for (const file of ["hub-env.sh", "hub-env.cjs", "reconcile-hub-config.py"]) {
      assert.match(dockerfile, new RegExp(`COPY [^\\n]*\\b${file.replace(".", "\\.")}\\b[^\\n]*/app/`), `${file} not copied to /app`);
    }
  });
});
