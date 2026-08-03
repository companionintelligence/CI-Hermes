/**
 * Telemetry (Sentry) settings resolution.
 *
 * Error reporting in CI-Hermes is **opt-in and off by default**: with no
 * `SENTRY_DSN` nothing is initialised, the SDK is never even `require`d, and no
 * network call is ever made. Two kill switches disable reporting even when a
 * DSN has been baked into an image (which is how a Hub-installed app receives
 * one), so an operator can always turn telemetry off without rebuilding:
 *
 *   - `CI_TELEMETRY=off`   — explicit opt-out
 *   - `CI_LOCAL_ONLY=true` — local-only mode must mean zero phone-home, see
 *     CI-Engineering/proposals/local-only-mode.md
 *
 * Ported from CI-Server's `common/telemetry/settings.ts` so the fleet shares one
 * env contract. Kept dependency-free CommonJS so it can be unit-tested (and
 * consulted by the wrapper's config endpoint) without loading the Sentry SDK.
 */

const FALSEY = new Set(["off", "false", "0", "no", "disabled"]);
const TRUTHY = new Set(["on", "true", "1", "yes", "enabled"]);

function read(env, key) {
  const value = typeof env[key] === "string" ? env[key].trim() : "";
  return value ? value : null;
}

/** `CI_TELEMETRY=off` (any falsey spelling) opts out; anything else leaves the DSN in charge. */
function isTelemetryOptedOut(env) {
  const value = read(env, "CI_TELEMETRY");
  return value !== null && FALSEY.has(value.toLowerCase());
}

/** Local-only mode forbids all egress, telemetry included. */
function isLocalOnly(env) {
  const value = read(env, "CI_LOCAL_ONLY");
  return value !== null && TRUTHY.has(value.toLowerCase());
}

/**
 * Resolve the gate.
 *
 * @param {NodeJS.ProcessEnv} env
 * @param {string} component  Value of the `component` tag on every event.
 * @returns {{enabled: boolean, disabledReason: string|null, dsn: string|null,
 *            environment: string, release: string|undefined, component: string,
 *            deploymentVersion: string|null}}
 */
function resolveTelemetrySettings(env, component) {
  const dsn = read(env, "SENTRY_DSN");
  const deploymentVersion = read(env, "CI_HERMES_VERSION") ?? read(env, "APP_VERSION");

  const base = {
    dsn,
    component,
    deploymentVersion,
    environment:
      read(env, "SENTRY_ENV") ?? read(env, "CI_HERMES_ENVIRONMENT") ?? read(env, "NODE_ENV") ?? "development",
    release:
      read(env, "SENTRY_RELEASE") ?? (deploymentVersion ? `${component}@${deploymentVersion}` : undefined),
  };

  // Order matters: report the *operator's* explicit choice ahead of "no DSN" so
  // the startup log tells them why reporting is off.
  if (isLocalOnly(env)) {
    return { ...base, enabled: false, disabledReason: "local-only" };
  }

  if (isTelemetryOptedOut(env)) {
    return { ...base, enabled: false, disabledReason: "opt-out" };
  }

  if (!dsn) {
    return { ...base, enabled: false, disabledReason: "no-dsn" };
  }

  return { ...base, enabled: true, disabledReason: null };
}

module.exports = {
  isLocalOnly,
  isTelemetryOptedOut,
  resolveTelemetrySettings,
};
