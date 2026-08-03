/**
 * Sentry bootstrap for the CI-Hermes wrapper.
 *
 * `init()` MUST run before `require("http")` / `require("ws")` in server.cjs:
 * the SDK patches Node's http internals on init, and instrumentation applied
 * after those modules are loaded misses everything they set up at require time.
 *
 * Reporting is opt-in. With no `SENTRY_DSN` this module resolves the gate,
 * returns, and never even `require`s `@sentry/node` — so a DSN-less container
 * pays nothing and makes no outbound connection. See `settings.cjs` for the
 * kill switches.
 *
 * Nothing here may change how the wrapper behaves: every entry point is wrapped
 * so a telemetry fault can never crash the app, alter an exit code, or hold
 * shutdown open.
 */

const { resolveTelemetrySettings } = require("./settings.cjs");
const scrub = require("./scrub.cjs");

const COMPONENT = "ci-hermes-web";

// server.cjs registers its own `uncaughtException`/`unhandledRejection`
// handlers, which deliberately log and KEEP SERVING rather than exiting. The
// SDK's equivalents would report the same crash a second time and can exit the
// process themselves — both are behaviour changes, so they are dropped and the
// wrapper's handlers capture explicitly instead.
const MANUALLY_HANDLED_INTEGRATIONS = new Set(["OnUncaughtException", "OnUnhandledRejection"]);

// Integrations whose whole job is to collect data this app must not send:
//   - Console: every console line in server.cjs narrates PTY/WebSocket traffic
//     ("Error processing terminal input: …"), so console breadcrumbs are a
//     direct path from the user's keystrokes into an event.
//   - LocalVariables*: frame locals here are terminal frames, PTY output and
//     SETUP_TOKEN. Gated off by `includeLocalVariables` today; dropped outright
//     so a future default flip cannot quietly turn them on.
const LEAKY_INTEGRATIONS = new Set(["Console", "LocalVariables", "LocalVariablesAsync"]);

// Release-health sessions are sent on start and exit even when nothing ever goes
// wrong. "Opt-in error reporting" should mean the appliance talks to Sentry when
// it has a crash to report and not otherwise, so the background session stream
// is dropped and reporting stays strictly error-driven.
const NON_ERROR_INTEGRATIONS = new Set(["ProcessSession"]);

/**
 * Whether a default integration survives into this app's client.
 *
 * Exported so the three removals above are asserted by the suite rather than
 * left to a code review: each one exists because keeping it would either change
 * how the wrapper behaves or collect data it must not send.
 */
function shouldKeepIntegration(name) {
  return (
    !MANUALLY_HANDLED_INTEGRATIONS.has(name) &&
    !LEAKY_INTEGRATIONS.has(name) &&
    !NON_ERROR_INTEGRATIONS.has(name)
  );
}

let sentry = null;
let settings = null;
let started = false;

/** Snapshot of the gate — safe to expose over HTTP (never includes the DSN). */
function status() {
  const resolved = settings || resolveTelemetrySettings(process.env, COMPONENT);

  return {
    component: resolved.component,
    enabled: resolved.enabled,
    disabledReason: resolved.disabledReason,
    environment: resolved.environment,
    release: resolved.release || null,
    // True only when Sentry.init actually ran: `enabled` is the operator's
    // decision, this is what the process is really doing.
    reporting: started,
  };
}

/** True when a Sentry client exists in this process. The ground truth for probes. */
function hasClient() {
  try {
    return Boolean(sentry && sentry.getClient());
  } catch {
    return false;
  }
}

function isEnabled() {
  return started;
}

/**
 * Resolve the gate and, if reporting is permitted, start the SDK.
 * Safe to call more than once; safe to call when reporting is disabled.
 */
function init(env = process.env) {
  if (started) {
    return status();
  }

  try {
    settings = resolveTelemetrySettings(env, COMPONENT);

    if (!settings.enabled || !settings.dsn) {
      // Stay silent for the ordinary no-DSN case; say something only when an
      // operator explicitly turned reporting off on an image that has a DSN,
      // so "why is nothing arriving in Sentry" is answerable from the log.
      if (settings.dsn && settings.disabledReason) {
        console.log(`[telemetry] error reporting disabled (${settings.disabledReason})`);
      }
      return status();
    }

    // Loaded lazily so the SDK is never even resolved on a DSN-less install.
    // A missing dependency must degrade to "no reporting", never to a boot
    // failure of the app the reporting is supposed to observe.
    try {
      sentry = require("@sentry/node");
    } catch (err) {
      console.warn(`[telemetry] @sentry/node unavailable, error reporting stays off: ${err.message}`);
      sentry = null;
      return status();
    }

    // Redact the literal values of the credentials this container was handed
    // (APP_SEED, HUB_MCP_API_KEY, CI_SERVER_TOKEN, provider keys) wherever they
    // appear — the terminal upgrade URL carries APP_SEED as a query parameter.
    scrub.registerEnvSecrets(env);

    sentry.init({
      dsn: settings.dsn,
      environment: settings.environment,
      release: settings.release,
      enabled: true,
      // Error reporting only. Tracing on a box that runs an agent with a live
      // shell would ship request shapes we have no consent to collect.
      tracesSampleRate: 0,
      profilesSampleRate: 0,
      // Never attach IPs, cookies or request bodies.
      sendDefaultPii: false,
      // The machine hostname identifies the household as surely as a home path.
      includeServerName: false,
      // Redundant with the LocalVariables filter below; both are cheap and this
      // is the option the SDK actually reads.
      includeLocalVariables: false,
      integrations: (defaults) => defaults.filter((integration) => shouldKeepIntegration(integration.name)),
      // Fail closed: if the scrubber ever throws we drop the event rather than
      // ship an unscrubbed one.
      beforeSend: (event) => {
        try {
          return scrub.scrubEvent(event);
        } catch {
          return null;
        }
      },
    });

    sentry.setTag("component", COMPONENT);

    if (settings.deploymentVersion) {
      sentry.setTag("deployment_version", settings.deploymentVersion);
    }

    started = true;
    console.log(`[telemetry] error reporting enabled (${COMPONENT}, env=${settings.environment})`);
  } catch (err) {
    // Telemetry must never take the app down with it.
    console.warn(`[telemetry] initialisation failed, error reporting stays off: ${err && err.message}`);
    started = false;
  }

  return status();
}

/**
 * Register an extra literal secret for redaction — for values minted at runtime
 * (per-boot tokens) that no pattern can recognise.
 */
function registerSecret(value) {
  try {
    scrub.registerSecret(value);
  } catch {
    /* never let redaction bookkeeping break the caller */
  }
}

/**
 * Report an error. No-op when reporting is off.
 *
 * `context` must hold only static, non-user strings (e.g. `{ where: "pty" }`).
 * Everything still passes through the scrubber, but the cheapest payload to
 * redact is the one that was never attached.
 */
function captureError(error, context) {
  if (!started || !sentry) {
    return;
  }

  try {
    sentry.withScope((scope) => {
      for (const [key, value] of Object.entries(context || {})) {
        if (value !== undefined) {
          scope.setExtra(key, value);
        }
      }

      sentry.captureException(error);
    });
  } catch {
    /* reporting a failure must not create one */
  }
}

/**
 * Flush buffered events, bounded so a wedged network can't hold shutdown open.
 * Resolves even when Sentry was never initialised.
 *
 * `Sentry.close(timeoutMs)` alone is NOT a real bound: its timeout only limits
 * how long the transport waits, and the promise still resolves on a later event
 * loop turn. Race it against a real timer so the caller's exit path always runs
 * on schedule. The timer is unref'd: it must never be the thing keeping the
 * process alive.
 */
async function flush(timeoutMs = 2000) {
  if (!started || !sentry) {
    return;
  }

  try {
    await Promise.race([
      sentry.close(timeoutMs).catch(() => undefined),
      new Promise((resolve) => {
        const timer = setTimeout(resolve, timeoutMs);
        if (typeof timer.unref === "function") {
          timer.unref();
        }
      }),
    ]);
  } catch {
    /* shutdown continues regardless */
  }
}

module.exports = {
  COMPONENT,
  captureError,
  flush,
  hasClient,
  init,
  isEnabled,
  registerSecret,
  shouldKeepIntegration,
  status,
};
