const { describe, test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const path = require("node:path");

const telemetry = require("../telemetry/index.cjs");

// ---------------------------------------------------------------------------
// The gate decides whether a Sentry client exists at all. Each case runs in its
// own process: Sentry keeps global state, so "was a client created?" can only be
// answered honestly by a process that started clean.
//
// Env is passed as an object to execFileSync — no shell, so nothing depends on
// word splitting (zsh does not split unquoted `$vars`, which is how probes
// silently run without their variables).
// ---------------------------------------------------------------------------

const INDEX_PATH = path.join(__dirname, "..", "telemetry", "index.cjs");
const FAKE_DSN = "https://abc123@o1.ingest.us.sentry.io/9999999";

let sdkInstalled = true;
try {
  require.resolve("@sentry/node");
} catch {
  sdkInstalled = false;
}

function probe(env) {
  const script = `
    const t = require(${JSON.stringify(INDEX_PATH)});
    const status = t.init();
    const sdkLoaded = Object.keys(require.cache).some((p) => p.includes(${JSON.stringify(
      path.join("@sentry", "node"),
    )}));
    process.stdout.write("\\n__PROBE__" + JSON.stringify({ ...status, hasClient: t.hasClient(), sdkLoaded }));
  `;

  const stdout = execFileSync(process.execPath, ["-e", script], {
    encoding: "utf8",
    env: { PATH: process.env.PATH, HOME: process.env.HOME, ...env },
  });

  return JSON.parse(stdout.slice(stdout.lastIndexOf("__PROBE__") + "__PROBE__".length));
}

describe("init: the four gate conditions", () => {
  test("no DSN — nothing initialises and the SDK is never even loaded", () => {
    const result = probe({});

    assert.equal(result.enabled, false);
    assert.equal(result.disabledReason, "no-dsn");
    assert.equal(result.reporting, false);
    assert.equal(result.hasClient, false);
    // The strongest form of "off by default": the dependency is not resolved,
    // so there is no transport, no queue and no outbound socket.
    assert.equal(result.sdkLoaded, false);
  });

  test("DSN — a client exists and reporting is on", (t) => {
    const result = probe({ SENTRY_DSN: FAKE_DSN });

    assert.equal(result.enabled, true);
    assert.equal(result.disabledReason, null);

    if (!sdkInstalled) {
      t.skip("@sentry/node not installed in this checkout");
      return;
    }

    assert.equal(result.reporting, true);
    assert.equal(result.hasClient, true);
    assert.equal(result.sdkLoaded, true);
  });

  test("DSN + CI_TELEMETRY=off — the operator's opt-out wins", () => {
    const result = probe({ SENTRY_DSN: FAKE_DSN, CI_TELEMETRY: "off" });

    assert.equal(result.enabled, false);
    assert.equal(result.disabledReason, "opt-out");
    assert.equal(result.reporting, false);
    assert.equal(result.hasClient, false);
    assert.equal(result.sdkLoaded, false);
  });

  test("DSN + CI_LOCAL_ONLY=true — local-only means zero phone-home", () => {
    const result = probe({ SENTRY_DSN: FAKE_DSN, CI_LOCAL_ONLY: "true" });

    assert.equal(result.enabled, false);
    assert.equal(result.disabledReason, "local-only");
    assert.equal(result.reporting, false);
    assert.equal(result.hasClient, false);
    assert.equal(result.sdkLoaded, false);
  });

  test("reports the component and environment it would use", () => {
    const result = probe({ SENTRY_DSN: FAKE_DSN, SENTRY_ENV: "production", CI_HERMES_VERSION: "v2026.7.20" });

    assert.equal(result.component, "ci-hermes-web");
    assert.equal(result.environment, "production");
    assert.equal(result.release, "ci-hermes-web@v2026.7.20");
  });
});

describe("init: default integrations that must not survive", () => {
  test("drops the SDK's own crash handlers", () => {
    // server.cjs registers handlers that log and KEEP SERVING. The SDK's would
    // report the same crash twice and can exit the process themselves — both
    // are behaviour changes reporting is not allowed to make.
    assert.equal(telemetry.shouldKeepIntegration("OnUncaughtException"), false);
    assert.equal(telemetry.shouldKeepIntegration("OnUnhandledRejection"), false);
  });

  test("drops console breadcrumbs and captured locals", () => {
    // Both are direct paths from the PTY into an event: this wrapper's log lines
    // narrate terminal traffic, and its frame locals ARE terminal frames.
    assert.equal(telemetry.shouldKeepIntegration("Console"), false);
    assert.equal(telemetry.shouldKeepIntegration("LocalVariables"), false);
    assert.equal(telemetry.shouldKeepIntegration("LocalVariablesAsync"), false);
  });

  test("drops release-health sessions, which phone home with no error to report", () => {
    assert.equal(telemetry.shouldKeepIntegration("ProcessSession"), false);
  });

  test("keeps the integrations that make a stack trace readable", () => {
    for (const name of ["ContextLines", "LinkedErrors", "Http", "RequestData", "Modules"]) {
      assert.equal(telemetry.shouldKeepIntegration(name), true, `${name} should be kept`);
    }
  });
});

describe("init: reporting never changes how the wrapper behaves", () => {
  test("capture and flush are inert no-ops while reporting is off", async () => {
    // This process has no DSN, so init() left the SDK unloaded. The wrapper
    // calls these from its crash handlers and its PTY paths on every boot.
    assert.equal(telemetry.init().enabled, false);
    assert.equal(telemetry.isEnabled(), false);
    assert.doesNotThrow(() => telemetry.captureError(new Error("boom"), { where: "test" }));
    assert.doesNotThrow(() => telemetry.captureError(undefined));
    assert.doesNotThrow(() => telemetry.registerSecret("a".repeat(64)));
    await telemetry.flush(50);
  });

  test("flush resolves promptly when there is nothing to flush", async () => {
    const startedAt = Date.now();
    await telemetry.flush(5000);

    // Not "within 5s" — it must not wait at all when reporting is off, or a
    // SIGTERM would sit on the timeout before the container could stop.
    assert.ok(Date.now() - startedAt < 1000, "flush must not block shutdown when reporting is off");
  });

  test("status is answerable without initialising anything", () => {
    const status = telemetry.status();

    assert.equal(status.component, "ci-hermes-web");
    assert.equal(typeof status.enabled, "boolean");
    assert.equal(status.reporting, false);
    // The endpoint that serves this must never be able to leak the DSN.
    assert.equal(Object.prototype.hasOwnProperty.call(status, "dsn"), false);
  });
});
