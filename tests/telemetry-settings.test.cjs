const { describe, test } = require("node:test");
const assert = require("node:assert/strict");

const {
  isLocalOnly,
  isTelemetryOptedOut,
  resolveTelemetrySettings,
} = require("../telemetry/settings.cjs");

// ---------------------------------------------------------------------------
// The gate is the whole privacy promise: "opt-in, off by default, and turnable
// off again without rebuilding the image". A DSN is baked into a Hub-installed
// image, so the kill switches are the only thing an operator has left.
// ---------------------------------------------------------------------------

const DSN = "https://abc123@o1.ingest.us.sentry.io/9999999";

describe("resolveTelemetrySettings: the opt-in gate", () => {
  test("is off with no DSN, and says why", () => {
    const settings = resolveTelemetrySettings({}, "ci-hermes-web");

    assert.equal(settings.enabled, false);
    assert.equal(settings.disabledReason, "no-dsn");
    assert.equal(settings.dsn, null);
  });

  test("is on with a DSN and nothing else set", () => {
    const settings = resolveTelemetrySettings({ SENTRY_DSN: DSN }, "ci-hermes-web");

    assert.equal(settings.enabled, true);
    assert.equal(settings.disabledReason, null);
    assert.equal(settings.dsn, DSN);
  });

  test("treats a whitespace-only DSN as absent", () => {
    const settings = resolveTelemetrySettings({ SENTRY_DSN: "   " }, "ci-hermes-web");

    assert.equal(settings.enabled, false);
    assert.equal(settings.disabledReason, "no-dsn");
  });

  test("CI_TELEMETRY beats a DSN baked into the image", () => {
    for (const value of ["off", "false", "0", "no", "disabled", "OFF", " Off "]) {
      const settings = resolveTelemetrySettings({ SENTRY_DSN: DSN, CI_TELEMETRY: value }, "ci-hermes-web");

      assert.equal(settings.enabled, false, `CI_TELEMETRY=${value} should disable reporting`);
      assert.equal(settings.disabledReason, "opt-out");
    }
  });

  test("CI_TELEMETRY=on leaves the DSN in charge", () => {
    assert.equal(resolveTelemetrySettings({ SENTRY_DSN: DSN, CI_TELEMETRY: "on" }, "c").enabled, true);
    // ...and cannot switch reporting ON when there is no DSN to report to.
    assert.equal(resolveTelemetrySettings({ CI_TELEMETRY: "on" }, "c").enabled, false);
  });

  test("CI_LOCAL_ONLY forbids all egress, telemetry included", () => {
    for (const value of ["true", "1", "yes", "on", "enabled", "TRUE"]) {
      const settings = resolveTelemetrySettings({ SENTRY_DSN: DSN, CI_LOCAL_ONLY: value }, "ci-hermes-web");

      assert.equal(settings.enabled, false, `CI_LOCAL_ONLY=${value} should disable reporting`);
      assert.equal(settings.disabledReason, "local-only");
    }
  });

  test("local-only outranks opt-out, which outranks no-dsn", () => {
    // The reported reason is the operator's most explicit choice, so the startup
    // log tells them which switch is the one actually holding reporting off.
    assert.equal(
      resolveTelemetrySettings({ SENTRY_DSN: DSN, CI_LOCAL_ONLY: "true", CI_TELEMETRY: "off" }, "c")
        .disabledReason,
      "local-only",
    );
    assert.equal(
      resolveTelemetrySettings({ CI_LOCAL_ONLY: "true", CI_TELEMETRY: "off" }, "c").disabledReason,
      "local-only",
    );
    assert.equal(resolveTelemetrySettings({ CI_TELEMETRY: "off" }, "c").disabledReason, "opt-out");
  });

  test("an unrecognised CI_LOCAL_ONLY value does not disable reporting", () => {
    assert.equal(resolveTelemetrySettings({ SENTRY_DSN: DSN, CI_LOCAL_ONLY: "maybe" }, "c").enabled, true);
  });
});

describe("resolveTelemetrySettings: environment and release", () => {
  test("defaults to development when nothing says otherwise", () => {
    assert.equal(resolveTelemetrySettings({}, "ci-hermes-web").environment, "development");
  });

  test("prefers SENTRY_ENV, then CI_HERMES_ENVIRONMENT, then NODE_ENV", () => {
    assert.equal(
      resolveTelemetrySettings(
        { SENTRY_ENV: "a", CI_HERMES_ENVIRONMENT: "b", NODE_ENV: "c" },
        "ci-hermes-web",
      ).environment,
      "a",
    );
    assert.equal(
      resolveTelemetrySettings({ CI_HERMES_ENVIRONMENT: "b", NODE_ENV: "c" }, "ci-hermes-web").environment,
      "b",
    );
    assert.equal(resolveTelemetrySettings({ NODE_ENV: "c" }, "ci-hermes-web").environment, "c");
  });

  test("derives a release from the deployment version, and lets SENTRY_RELEASE win", () => {
    assert.equal(
      resolveTelemetrySettings({ CI_HERMES_VERSION: "v2026.7.20" }, "ci-hermes-web").release,
      "ci-hermes-web@v2026.7.20",
    );
    assert.equal(
      resolveTelemetrySettings({ CI_HERMES_VERSION: "v1", SENTRY_RELEASE: "explicit" }, "ci-hermes-web")
        .release,
      "explicit",
    );
    assert.equal(resolveTelemetrySettings({}, "ci-hermes-web").release, undefined);
  });

  test("falls back to APP_VERSION for the deployment version", () => {
    assert.equal(resolveTelemetrySettings({ APP_VERSION: "9.9" }, "c").deploymentVersion, "9.9");
  });
});

describe("kill-switch predicates", () => {
  test("isTelemetryOptedOut only fires on a falsey spelling", () => {
    assert.equal(isTelemetryOptedOut({ CI_TELEMETRY: "off" }), true);
    assert.equal(isTelemetryOptedOut({ CI_TELEMETRY: "on" }), false);
    assert.equal(isTelemetryOptedOut({}), false);
    assert.equal(isTelemetryOptedOut({ CI_TELEMETRY: "" }), false);
  });

  test("isLocalOnly only fires on a truthy spelling", () => {
    assert.equal(isLocalOnly({ CI_LOCAL_ONLY: "1" }), true);
    assert.equal(isLocalOnly({ CI_LOCAL_ONLY: "0" }), false);
    assert.equal(isLocalOnly({}), false);
  });
});
