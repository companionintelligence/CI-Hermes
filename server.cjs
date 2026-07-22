const http = require("http");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const memoryGate = require("./memory-gate.cjs");
const pty = require("/app/node_modules/node-pty");
const WebSocket = require("/app/node_modules/ws");

const PORT = parseInt(process.env.PORT || "18789");
// Anti-CSWSH token: browsers don't enforce same-origin on WebSocket upgrades,
// so without this any site could connect to /ci/api/terminal and hijack the PTY.
// APP_SEED (per-app secret from CI marketplace) is embedded in the served HTML.
const SETUP_TOKEN = process.env.APP_SEED || "";

// Dedicated per-process token for the local memory-gate dismiss actions
// (/__ci_memory/defer + /skip). Deliberately NOT SETUP_TOKEN (=APP_SEED, the
// RCE-grade terminal secret): those actions are low-value (dismiss a prompt), so
// they must not reuse — nor risk leaking — the terminal secret. Minted fresh per
// boot and carried in the POST body (never the URL) so it can't leak via proxy
// logs / Referer / history.
const MEMORY_ACTION_TOKEN = crypto.randomBytes(32).toString("hex");

/**
 * Byte-safe constant-time token compare: compares BYTE lengths before
 * crypto.timingSafeEqual, which throws a RangeError on unequal-length buffers
 * (a multi-byte value can match the JS string length while differing in bytes).
 */
function tokensMatch(provided, expected) {
  if (!expected) return false;
  const a = Buffer.from(String(provided ?? ""));
  const b = Buffer.from(expected);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

const DATA_DIR = "/opt/data";
const DASHBOARD_HOST = "127.0.0.1";
const DASHBOARD_PORT = 9119;
const DEFAULT_PTY_IDLE_GRACE_MS = 1800000;
const ALLOW_SAME_ORIGIN_WS_FALLBACK = ["1", "true", "yes", "on"].includes(
  String(process.env.ALLOW_SAME_ORIGIN_WS_FALLBACK || "").toLowerCase(),
);
const HUB_ENV_FILE = path.join(DATA_DIR, ".env.hub-bootstrap");
const HUB_ENV_PREFIXES = [
  "OPENAI_",
  "HERMES_",
  "CUSTOM_",
  "ANTHROPIC_",
  "GEMINI_",
  "GOOGLE_",
  "OLLAMA_",
];

function isAllowedHubEnvKey(key) {
  return HUB_ENV_PREFIXES.some((prefix) => key.startsWith(prefix));
}

function loadHubBootstrapEnv() {
  const out = {};
  try {
    if (!fs.existsSync(HUB_ENV_FILE)) {
      return out;
    }
    const text = fs.readFileSync(HUB_ENV_FILE, "utf8");
    for (const rawLine of text.split(/\r?\n/)) {
      const line = rawLine.trim();
      if (!line || line.startsWith("#")) {
        continue;
      }
      const eqIdx = line.indexOf("=");
      if (eqIdx <= 0) {
        continue;
      }
      const key = line.slice(0, eqIdx).trim();
      if (!isAllowedHubEnvKey(key)) {
        continue;
      }
      let value = line.slice(eqIdx + 1);
      if (
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))
      ) {
        value = value.slice(1, -1);
      }
      out[key] = value;
    }
  } catch (e) {
    console.warn(`Failed to read ${HUB_ENV_FILE}: ${e.message}`);
  }
  return out;
}

function parseNonNegativeInt(rawValue, fallbackValue) {
  const parsed = Number.parseInt(String(rawValue || ""), 10);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return fallbackValue;
  }
  return parsed;
}

// Keep PTY alive long enough for browser reconnects without resetting chat context.
const PTY_IDLE_GRACE_MS = parseNonNegativeInt(
  process.env.PTY_IDLE_GRACE_MS,
  DEFAULT_PTY_IDLE_GRACE_MS,
);

let ptyProcess = null;
let activeWs = null;
let ptyCleanupTimer = null;

const TERMINAL_HTML = fs.readFileSync("/app/terminal.html", "utf8");
const LOGO = fs.readFileSync(path.join(__dirname, "logo.webp"));
// Companion Memory logo, shown next to the app logo on the connect interstitial
// (served at MEMORY_LOGO_PATH). Read once, guarded: a missing asset degrades the
// interstitial to just the app logo rather than crashing the wrapper on boot.
let MEMORY_LOGO = null;
try {
  MEMORY_LOGO = fs.readFileSync(path.join(__dirname, "assets", "ci-memory-logo.webp"));
} catch (err) {
  console.warn(`[ci-memory] ci-memory-logo.webp missing, interstitial will omit it: ${err.message}`);
}

function stripLeakedOscResponses(data) {
  if (typeof data !== "string" || !data) {
    return data;
  }

  // Some shells/plugins query OSC 11 (background color). In web terminals this
  // can occasionally leak back into stdin as literal text like
  // "]11;rgb:1111/1111/1313". Strip those fragments before they hit the PTY.
  return data
    .replace(
      /\u001b\]11;rgb:[0-9a-fA-F]{2,4}\/[0-9a-fA-F]{2,4}\/[0-9a-fA-F]{2,4}(?:\u0007|\u001b\\)/g,
      "",
    )
    .replace(
      /\]11;rgb:[0-9a-fA-F]{2,4}\/[0-9a-fA-F]{2,4}\/[0-9a-fA-F]{2,4}/g,
      "",
    );
}

function normalizeHostName(hostValue) {
  if (!hostValue) {
    return "";
  }
  // Host/port splitting is handled separately; keep the hostname untouched
  // (except casing/whitespace) so IPv6 hosts like ::1 are not mangled.
  return String(hostValue).trim().toLowerCase();
}

function parseHostAndPort(hostValue) {
  const raw = String(hostValue || "").trim();
  if (!raw) {
    return { hostname: "", port: "" };
  }

  // Support bracketed IPv6 hosts: [::1]:9119
  if (raw.startsWith("[")) {
    const end = raw.indexOf("]");
    if (end !== -1) {
      const hostname = raw.slice(1, end).toLowerCase();
      const rest = raw.slice(end + 1);
      if (rest.startsWith(":")) {
        return { hostname, port: rest.slice(1) };
      }
      return { hostname, port: "" };
    }
  }

  const parts = raw.split(":");
  if (parts.length > 1) {
    const maybePort = parts[parts.length - 1];
    if (/^\d+$/.test(maybePort)) {
      return {
        hostname: parts.slice(0, -1).join(":").toLowerCase(),
        port: maybePort,
      };
    }
  }

  return { hostname: raw.toLowerCase(), port: "" };
}

function defaultPortForProto(proto) {
  const value = String(proto || "").toLowerCase();
  if (value === "https" || value === "wss") {
    return "443";
  }
  return "80";
}

function resolveRequestPort(req, parsedHost, fallbackPort) {
  if (parsedHost.port) {
    return parsedHost.port;
  }

  const forwardedProto = String(req.headers["x-forwarded-proto"] || "")
    .split(",")[0]
    .trim()
    .toLowerCase();

  // Some proxies report websocket transport metadata (ws/80) here even when
  // the browser Origin is https/443. In that case, prefer Origin-derived port
  // for same-origin validation.
  if ((forwardedProto === "ws" || forwardedProto === "wss") && fallbackPort) {
    return String(fallbackPort);
  }

  const forwardedPort = String(req.headers["x-forwarded-port"] || "").trim();
  if (/^\d+$/.test(forwardedPort)) {
    return forwardedPort;
  }

  if (!forwardedProto && fallbackPort) {
    return String(fallbackPort);
  }
  return defaultPortForProto(forwardedProto || "http");
}

function clearPtyCleanupTimer() {
  if (ptyCleanupTimer) {
    clearTimeout(ptyCleanupTimer);
    ptyCleanupTimer = null;
  }
}

function killPty() {
  if (ptyProcess) {
    try {
      ptyProcess.kill();
    } catch (e) {}
    ptyProcess = null;
  }
}

function schedulePtyCleanup() {
  clearPtyCleanupTimer();
  ptyCleanupTimer = setTimeout(() => {
    const hasActiveClient = activeWs && activeWs.readyState === WebSocket.OPEN;
    if (!hasActiveClient) {
      killPty();
      console.log(
        "No active terminal client; PTY closed after idle grace period",
      );
    }
    ptyCleanupTimer = null;
  }, PTY_IDLE_GRACE_MS);
}

function startPtyIfNeeded() {
  if (ptyProcess) {
    return;
  }

  const sessionPty = pty.spawn("/app/start-hermes.sh", [], {
    name: "xterm-256color",
    cols: 80,
    rows: 24,
    cwd: DATA_DIR,
    env: {
      ...process.env,
      ...loadHubBootstrapEnv(),
      TERM: "xterm-256color",
      HOME: DATA_DIR,
    },
  });

  ptyProcess = sessionPty;

  sessionPty.onData((data) => {
    try {
      if (activeWs && activeWs.readyState === WebSocket.OPEN) {
        activeWs.send(JSON.stringify({ type: "output", data }));
      }
    } catch (e) {
      console.error("Error sending PTY output:", e.message);
    }
  });

  sessionPty.onExit(({ exitCode }) => {
    console.log(`PTY exited with code ${exitCode}`);
    const wasActiveSession = ptyProcess === sessionPty;
    try {
      if (activeWs && activeWs.readyState === WebSocket.OPEN) {
        activeWs.send(JSON.stringify({ type: "exit", code: exitCode }));
      }
    } catch (e) {
      console.error("Error sending exit message:", e.message);
    }
    if (wasActiveSession) {
      ptyProcess = null;
    }
  });
}

function injectTerminalShortcut(html) {
  if (
    !html ||
    typeof html !== "string" ||
    html.includes("ci-terminal-shortcut")
  ) {
    return html;
  }

  const styleBlock = `<style id="ci-terminal-shortcut-style">\n.ci-terminal-shortcut {\n  position: fixed;\n  right: 18px;\n  bottom: 18px;\n  z-index: 2147483000;\n  display: inline-flex;\n  align-items: center;\n  gap: 6px;\n  padding: 10px 14px;\n  border-radius: 10px;\n  border: 1px solid rgba(255, 191, 0, 0.35);\n  background: rgba(18, 18, 18, 0.92);\n  color: #FFBF00;\n  text-decoration: none;\n  font-family: system-ui, -apple-system, Segoe UI, sans-serif;\n  font-size: 13px;\n  font-weight: 600;\n  line-height: 1;\n  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.35);\n}\n.ci-terminal-shortcut:hover {\n  border-color: #FFBF00;\n  color: #FFD75A;\n}\n@media (max-width: 700px) {\n  .ci-terminal-shortcut {\n    right: 12px;\n    bottom: 12px;\n    padding: 9px 12px;\n    font-size: 12px;\n  }\n}\n</style>`;

  const buttonMarkup =
    '<a class="ci-terminal-shortcut" href="/terminal" aria-label="Open Hermes terminal">Open Terminal</a>';

  let out = html;
  if (/<\/head>/i.test(out)) {
    out = out.replace(/<\/head>/i, `${styleBlock}</head>`);
  } else {
    out = styleBlock + out;
  }

  if (/<body[^>]*>/i.test(out)) {
    out = out.replace(/<body[^>]*>/i, (match) => `${match}${buttonMarkup}`);
  } else {
    out += buttonMarkup;
  }

  return out;
}

function shouldProxyResponseHaveBody(proxyRes, method) {
  const statusCode = Number(proxyRes.statusCode || 0);
  if (String(method || "").toUpperCase() === "HEAD") {
    return false;
  }
  if (statusCode === 204 || statusCode === 304) {
    return false;
  }
  if (statusCode >= 100 && statusCode < 200) {
    return false;
  }
  if (statusCode === 205) {
    return false;
  }
  return true;
}

function blockHermesUpdate(req, res) {
  res.writeHead(403, {
    "Content-Type": "text/plain; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end("Hermes updates are managed by CI marketplace app updates.");
}

function blockGatewayRestart(req, res) {
  res.writeHead(403, {
    "Content-Type": "text/plain; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end(
    "Gateway restarts are managed by CI marketplace. Restart Hermes from the CI marketplace homescreen.",
  );
}

function handleCiAuthMe(req, res) {
  // Keep dashboard auth semantics unchanged to avoid UI assumptions on a custom
  // auth payload shape. Access control is still enforced upstream by CI-Hub
  // forward-auth at Traefik layer.
  const payload = { detail: "Unauthorized" };
  res.writeHead(401, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end(JSON.stringify(payload));
}

// The CI marketplace app proxy rewrites the inbound Host header to an internal
// routing name (e.g. <app>.ci.lan) while the browser Origin stays the public
// host (e.g. <app>.companionintelligence.com), so Host will never equal Origin
// behind the proxy. CI injects the app's public host via these env vars; accept
// the matching full origin (scheme + host + port) as same-origin. Without this,
// WebSocket upgrades from the real browser Origin are rejected (403) whenever
// the app runs behind the marketplace proxy.
function computeAllowedOrigins() {
  const origins = new Set();
  const add = (value) => {
    if (!value) return;
    const raw = String(value).trim();
    if (!raw) return;
    // Bare hosts are served publicly over HTTPS. Parsing through the URL API
    // normalizes case, brackets IPv6 literals, and yields a scheme+host+port
    // origin so the comparison stays exact and port-aware.
    try {
      const url = new URL(raw.includes("://") ? raw : `https://${raw}`);
      origins.add(url.origin);
    } catch (e) {
      // Ignore values that are not a valid host/URL.
    }
  };
  add(process.env.APP_HOST);
  add(process.env.APP_DOMAIN);
  add(process.env.APP_EXPOSED_DOMAIN);
  add(process.env.APP_URL);
  add(process.env.APP_PUBLIC_URL);
  return origins;
}

const ALLOWED_ORIGINS = computeAllowedOrigins();

function isSameOriginUpgrade(req) {
  try {
    const origin = String(req.headers.origin || "").trim();
    if (!origin) {
      return false;
    }
    const originUrl = new URL(origin);

    // Behind the CI marketplace proxy the Host header is rewritten to an
    // internal routing name, so it never matches the public browser Origin.
    // Accept when the full Origin (scheme + host + port) matches a configured
    // public origin — this still enforces scheme and port, unlike a
    // hostname-only check.
    if (ALLOWED_ORIGINS.has(originUrl.origin)) {
      return true;
    }

    const requestHost = parseHostAndPort(req.headers.host || "");
    const originHost = parseHostAndPort(originUrl.host || "");

    const requestHostName = normalizeHostName(requestHost.hostname);
    const originHostName = normalizeHostName(originHost.hostname);
    if (!requestHostName || requestHostName !== originHostName) {
      return false;
    }

    const originPort =
      originHost.port ||
      defaultPortForProto(originUrl.protocol.replace(":", ""));
    const requestPort = resolveRequestPort(req, requestHost, originPort);

    return requestPort === originPort;
  } catch (e) {
    return false;
  }
}

// Proxy HTTP requests to the dashboard container
function proxyToDashboard(req, res) {
  const options = {
    hostname: DASHBOARD_HOST,
    port: DASHBOARD_PORT,
    path: req.url,
    method: req.method,
    headers: {
      ...req.headers,
      // Keep responses uncompressed so we can inject lightweight CI UI affordances.
      "accept-encoding": "identity",
      // Hermes validates Host against its loopback dashboard bind address.
      // Rewriting is safe in CI marketplace because app_proxy authenticates requests
      // before they reach this wrapper; direct network exposure is not supported.
      host: DASHBOARD_HOST + ":" + DASHBOARD_PORT,
    },
  };

  const proxy = http.request(options, (proxyRes) => {
    const contentType = String(
      proxyRes.headers["content-type"] || "",
    ).toLowerCase();
    const shouldInject = contentType.includes("text/html");
    const bodyAllowed = shouldProxyResponseHaveBody(proxyRes, req.method);

    if (!bodyAllowed) {
      res.writeHead(proxyRes.statusCode || 200, proxyRes.headers);
      proxyRes.resume();
      res.end();
      return;
    }

    if (!shouldInject) {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
      return;
    }

    let body = "";
    proxyRes.setEncoding("utf8");
    proxyRes.on("data", (chunk) => {
      body += chunk;
    });
    proxyRes.on("end", () => {
      const modified = injectTerminalShortcut(body);
      const headers = { ...proxyRes.headers };
      delete headers["content-length"];
      delete headers["content-encoding"];
      delete headers.etag;
      res.writeHead(proxyRes.statusCode || 200, headers);
      res.end(modified);
    });
  });

  proxy.on("error", () => {
    res.writeHead(502, {
      "Content-Type": "text/html",
      "Cache-Control": "no-store",
    });
    res.end(
      "<html><body><h2>Dashboard is starting...</h2><p>Please wait a moment and refresh.</p></body></html>",
    );
  });

  req.pipe(proxy);
}

function writeProxyUpgradeResponse(socket, proxyRes) {
  const statusCode = proxyRes.statusCode || 101;
  const statusMessage = proxyRes.statusMessage || "Switching Protocols";
  socket.write(`HTTP/1.1 ${statusCode} ${statusMessage}\r\n`);

  for (const [key, value] of Object.entries(proxyRes.headers || {})) {
    if (Array.isArray(value)) {
      for (const entry of value) {
        socket.write(`${key}: ${entry}\r\n`);
      }
      continue;
    }
    if (value !== undefined) {
      socket.write(`${key}: ${value}\r\n`);
    }
  }

  socket.write("\r\n");
}

function writeUpgradeFailureResponse(socket, statusCode, message) {
  const status = Number(statusCode) || 502;
  const text = String(message || "WebSocket upgrade failed.");
  const body = `${text}\n`;
  socket.write(`HTTP/1.1 ${status} Bad Gateway\r\n`);
  socket.write("Content-Type: text/plain; charset=utf-8\r\n");
  socket.write(`Content-Length: ${Buffer.byteLength(body, "utf8")}\r\n`);
  socket.write("Connection: close\r\n");
  socket.write("Cache-Control: no-store\r\n");
  socket.write("\r\n");
  socket.end(body);
}

function proxyDashboardUpgrade(req, socket, head) {
  const dashboardHostHeader = DASHBOARD_HOST + ":" + DASHBOARD_PORT;
  const proxy = http.request({
    hostname: DASHBOARD_HOST,
    port: DASHBOARD_PORT,
    path: req.url,
    method: req.method,
    headers: {
      ...req.headers,
      host: dashboardHostHeader,
      origin: `http://${dashboardHostHeader}`,
    },
  });

  proxy.on("upgrade", (proxyRes, proxySocket, proxyHead) => {
    writeProxyUpgradeResponse(socket, proxyRes);

    if (head && head.length) {
      proxySocket.write(head);
    }
    if (proxyHead && proxyHead.length) {
      socket.write(proxyHead);
    }

    proxySocket.pipe(socket);
    socket.pipe(proxySocket);

    proxySocket.on("error", () => {
      socket.destroy();
    });
    socket.on("error", () => {
      proxySocket.destroy();
    });
  });

  proxy.on("response", (proxyRes) => {
    const upstreamStatus = Number(proxyRes.statusCode || 0);
    proxyRes.resume();
    writeUpgradeFailureResponse(
      socket,
      502,
      upstreamStatus
        ? `Upstream returned ${upstreamStatus} instead of switching protocols.`
        : "Upstream rejected WebSocket upgrade.",
    );
  });

  proxy.on("error", () => {
    socket.end("HTTP/1.1 502 Bad Gateway\r\n\r\n");
  });

  proxy.end();
}

// ── Companion Memory connect interstitial ───────────────────────────────────
// Shown before the dashboard when memory is not yet connected, so the user can
// connect (or dismiss) rather than silently running without long-term memory.
// The Hub owns the OAuth-style flow; this wrapper renders the gate and relays
// the skip/defer choices. Paths namespaced under /__ci_memory/.
const MEMORY_DEFER_COOKIE = "ci_memory_deferred";
// Grace window (seconds) for the "Maybe later" (defer) choice. Long enough to
// carry the post-dismiss redirect, short enough that the next fresh launch/reload
// re-prompts. Deliberately NOT a session cookie — that survived tab-close +
// relaunch, making "defer" feel as permanent as "Don't ask again".
const MEMORY_DEFER_GRACE_SECONDS = 30;
const MEMORY_DEFER_PATH = "/__ci_memory/defer";
const MEMORY_SKIP_PATH = "/__ci_memory/skip";
const MEMORY_LOGO_PATH = "/__ci_memory/ci-memory-logo.webp";

/** Hub internal base URL, reachable from this container. */
function hubInternalBase() {
  return (process.env.CI_HUB_URL || process.env.HUB_URL || "").trim().replace(/\/+$/, "");
}

/** Auth header for wrapper->Hub memory-connect calls: this app's own managed key. */
function mcpAuthHeaders() {
  const key = (process.env.HUB_MCP_API_KEY || "").trim();
  return key ? { Authorization: `Bearer ${key}` } : {};
}

/** Whether memory creds are already present (Hub-injected or operator-set). */
function hasMemoryCreds() {
  return !!(process.env.CI_SERVER_URL && process.env.CI_SERVER_TOKEN && process.env.CI_SERVER_ENABLED !== "false");
}

/** Whether the request carries the short-lived "deferred" cookie (grace window). */
function hasMemoryDeferCookie(req) {
  return (req.headers.cookie || "").split(";").some((c) => c.trim().startsWith(`${MEMORY_DEFER_COOKIE}=`));
}

/**
 * Read a small urlencoded request body (bounded), resolving to parsed params.
 * The memory-gate action token travels in the POST body (not the URL), so a
 * cross-site page still cannot forge it (same-origin policy) while it no longer
 * leaks through request logs / Referer / history.
 */
function readFormBody(req, limit = 8192) {
  return new Promise((resolve) => {
    let data = "";
    let done = false;
    const finish = (value) => {
      if (!done) {
        done = true;
        resolve(new URLSearchParams(value));
      }
    };
    req.on("data", (chunk) => {
      if (done) return;
      data += chunk;
      // Over the (generous) cap → treat as no token. Stop accumulating (via the
      // `done` guard) but do NOT destroy the socket here, so the awaiting handler
      // still delivers its 403 on a live connection.
      if (data.length > limit) {
        finish("");
      }
    });
    req.on("end", () => finish(data));
    req.on("error", () => finish(""));
    // Resolve on close/abort too, so a client that stalls without a clean
    // end/error can never leave this promise (and the awaiting handler) pending.
    req.on("close", () => finish(""));
  });
}

/** Escape a value for safe interpolation into an HTML attribute. */
function escapeHtmlAttr(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Minimal, self-contained interstitial page. Matches the Companion Memory
 * (CI-Import-Tools) sign-in aesthetic: navy background, elevated card, the
 * app's own logo paired with the Companion Memory logo ("app -> memory"), and a
 * teal brand-gradient pill. The app logo is served at /logo.webp and the memory
 * logo at MEMORY_LOGO_PATH. Colors mirror the import-tools dark theme tokens
 * (with a light-scheme fallback).
 */
function renderMemoryGateHtml(connectUrl) {
  // Connector + Companion Memory mark, appended after the app logo. Omitted
  // entirely (no dangling arrow) when the mark asset is unavailable.
  const cmGlyph = MEMORY_LOGO
    ? `<svg class="link" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="4" y1="12" x2="18" y2="12" /><polyline points="12 6 18 12 12 18" /></svg><img class="cm" src="${MEMORY_LOGO_PATH}" alt="Companion Memory" />`
    : "";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Connect to Companion Memory</title>
<style>
  :root{color-scheme:dark;--bg:#041620;--card:#0a222e;--border:#1f4a55;--fg:#f5f8fa;--fg-dim:#9bb2b7;--brand-grad:linear-gradient(135deg,#0b6e74 0%,#079d99 100%);--on-accent:#fff;--shadow:0 6px 24px rgba(4,22,32,.22)}
  @media (prefers-color-scheme:light){:root{color-scheme:light;--bg:#f3f3f3;--card:#f7f7f9;--border:#d3dddf;--fg:#010f16;--fg-dim:#4f6168;--shadow:0 6px 24px rgba(4,22,32,.12)}}
  *{box-sizing:border-box}
  body{font-family:"Montserrat",system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--fg);padding:40px 20px}
  .card{width:100%;max-width:420px;text-align:center;background:var(--card);border:1px solid var(--border);border-radius:14px;padding:36px 28px;box-shadow:var(--shadow)}
  .brand{display:flex;align-items:center;justify-content:center;gap:14px;margin:0 auto 22px}
  .applogo{width:56px;height:56px;object-fit:contain;background:#fff;border-radius:14px;padding:8px;box-shadow:0 2px 10px rgba(0,0,0,.28)}
  .brand .link{color:var(--fg-dim);display:flex;align-items:center}
  .cm{width:56px;height:56px;object-fit:contain;border-radius:14px;background:#000;box-shadow:0 2px 10px rgba(0,0,0,.28)}
  h1{font-size:20px;font-weight:700;margin:0 0 8px}
  p{line-height:1.5;color:var(--fg-dim);font-size:14px;margin:0 0 22px}
  .actions{display:flex;flex-direction:column;gap:10px}
  .actions form{margin:0}
  .btn{display:block;width:100%;padding:11px 20px;border-radius:999px;border:0;font-size:15px;font-weight:600;line-height:1.2;cursor:pointer;text-align:center;text-decoration:none;font-family:inherit}
  .primary{background:var(--brand-grad);color:var(--on-accent)}
  .primary:hover{filter:brightness(1.06)}
  .secondary{background:transparent;color:var(--fg-dim);border:1px solid var(--border)}
  .secondary:hover{color:var(--fg);border-color:var(--fg-dim)}
</style></head>
<body><main class="card">
  <div class="brand">
    <img class="applogo" src="/logo.webp" alt="Hermes" />${cmGlyph}
  </div>
  <h1>Give Hermes long-term memory</h1>
  <p>Connect to your Companion Memory so Hermes remembers your context across
     sessions. You'll sign in with Companion Intelligence and approve access; you
     can disconnect any time.</p>
  <div class="actions">
    <a class="btn primary" href="${escapeHtmlAttr(connectUrl)}">Sign in with Companion Intelligence</a>
    <form method="POST" action="${MEMORY_DEFER_PATH}"><input type="hidden" name="t" value="${MEMORY_ACTION_TOKEN}" /><button class="btn secondary" type="submit">Maybe later</button></form>
    <form method="POST" action="${MEMORY_SKIP_PATH}"><input type="hidden" name="t" value="${MEMORY_ACTION_TOKEN}" /><button class="btn secondary" type="submit">Don't ask again</button></form>
  </div>
</main></body></html>`;
}

/**
 * Serve the connect interstitial on the top-level dashboard load when memory is
 * not connected and the user hasn't dismissed it. Fails open (returns false) on
 * any uncertainty so a Hub hiccup never blocks the app.
 */
async function maybeServeMemoryGate(req, res, requestPath) {
  // Gate EVERY top-level HTML navigation, regardless of which SPA route the user
  // opens or refreshes (/, /terminal, /chat, …) — not just the known entry points
  // — so a disconnected app re-prompts everywhere, not only at the root. Never
  // gate the wrapper's own /__ci_memory/* paths (defer/skip/logo), nor
  // non-navigation requests: API/XHR, static assets, and WebSocket upgrades don't
  // carry `Sec-Fetch-Dest: document` (and don't Accept text/html on older
  // browsers), so returning the interstitial HTML for them would break the app.
  if (req.method !== "GET" || requestPath.startsWith("/__ci_memory")) return false;
  const secFetchDest = String(req.headers["sec-fetch-dest"] || "");
  const isNavigation = secFetchDest ? secFetchDest === "document" : String(req.headers.accept || "").includes("text/html");
  if (!isNavigation) return false;
  if (hasMemoryCreds()) return false;
  if (hasMemoryDeferCookie(req)) return false;

  const appUrn = (process.env.CI_APP_URN || "").trim();
  const hubBase = hubInternalBase();
  if (!appUrn || !hubBase) return false;

  try {
    // `clientHost` tells the Hub where the BROWSER is. This request is
    // server-to-server over the internal network, so the Hub would otherwise see
    // its own container hostname and could never tell a LAN visitor from a remote
    // one — which is what decides whether the LAN launcher is usable.
    const stateUrl = memoryGate.buildStateUrl(hubBase, appUrn, req.headers.host);

    const resp = await fetch(stateUrl, {
      headers: mcpAuthHeaders(),
      signal: AbortSignal.timeout(4000),
    });
    if (!resp.ok) return false;
    const { state, connectUrl, connectUrlLocal, reason } = await resp.json();
    if (!memoryGate.shouldPromptForState(state)) return false;
    // Only ever link to an http(s) Hub URL — never a javascript:/data: scheme.
    // Public route first; the LAN launcher is the fallback the Hub supplies when
    // its public origin is down and this browser is on the local network.
    const safeConnectUrl = memoryGate.selectLauncher({ connectUrl, connectUrlLocal });
    if (!safeConnectUrl) {
      // Fail open, but not fail silent: a gate that vanishes reads as "memory is
      // connected". The Hub's app-detail badge still shows the app as
      // disconnected; this line is what makes the reason diagnosable here.
      console.warn(`[ci-memory] connect gate suppressed (${reason || "no launcher available"}); letting the user through`);
      return false;
    }

    res.writeHead(200, {
      "Content-Type": "text/html",
      "Cache-Control": "no-store",
      // Anti-clickjacking: the gate has consent-suppression buttons (skip/defer),
      // so it must never be framed (matches the CI-Server consent page).
      "X-Frame-Options": "DENY",
      "Content-Security-Policy": "frame-ancestors 'none'",
    });
    res.end(renderMemoryGateHtml(memoryGate.launcherWithNext(safeConnectUrl, memoryGate.requestAbsoluteUrl(req))));
    return true;
  } catch {
    return false;
  }
}

/** Handle the interstitial's local defer/skip actions. Returns true if handled. */
async function handleMemoryAction(req, res, requestPath) {
  if (requestPath !== MEMORY_DEFER_PATH && requestPath !== MEMORY_SKIP_PATH) return false;

  // POST-only + anti-CSWSH token carried in the body (byte-safe compare).
  const body = req.method === "POST" ? await readFormBody(req) : new URLSearchParams();
  if (req.method !== "POST" || !tokensMatch(body.get("t"), MEMORY_ACTION_TOKEN)) {
    res.writeHead(403, { "Content-Type": "text/plain" });
    res.end("Forbidden");
    return true;
  }

  if (requestPath === MEMORY_DEFER_PATH) {
    // Return to the app root — where the marketplace launches the app and where
    // the gate was shown — not the /terminal sub-page.
    res.writeHead(302, {
      Location: "/",
      "Set-Cookie": `${MEMORY_DEFER_COOKIE}=1; Path=/; Max-Age=${MEMORY_DEFER_GRACE_SECONDS}; HttpOnly; SameSite=Lax`,
    });
    res.end();
    return true;
  }

  const appUrn = (process.env.CI_APP_URN || "").trim();
  const hubBase = hubInternalBase();
  if (appUrn && hubBase) {
    try {
      await fetch(`${hubBase}/api/memory-connect/apps/${encodeURIComponent(appUrn)}/skip`, {
        method: "POST",
        headers: mcpAuthHeaders(),
        signal: AbortSignal.timeout(4000),
      });
    } catch {
      // best-effort
    }
  }
  res.writeHead(302, { Location: "/" });
  res.end();
  return true;
}

const server = http.createServer(async (req, res) => {
  const requestUrl = new URL(req.url || "/", "http://localhost");
  const requestPath = requestUrl.pathname.replace(/\/+$/, "");

  // Companion Memory connect interstitial: handle its local actions, then offer
  // the gate on the top-level dashboard load (before proxying to the dashboard).
  if (await handleMemoryAction(req, res, requestPath)) {
    return;
  }
  if (await maybeServeMemoryGate(req, res, requestPath)) {
    return;
  }

  // Serve terminal page at /terminal (CI marketplace app manifest points here)
  if (requestPath === "/terminal") {
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(TERMINAL_HTML.replace("__SETUP_TOKEN__", SETUP_TOKEN));
    return;
  }

  // Serve static assets for terminal UI
  if (requestPath === "/logo.webp") {
    res.writeHead(200, {
      "Content-Type": "image/webp",
      "Cache-Control": "public, max-age=86400",
    });
    res.end(LOGO);
    return;
  }

  // Companion Memory logo for the connect interstitial (served from assets/).
  if (MEMORY_LOGO && requestPath === MEMORY_LOGO_PATH) {
    res.writeHead(200, {
      "Content-Type": "image/webp",
      "Cache-Control": "public, max-age=86400",
    });
    res.end(MEMORY_LOGO);
    return;
  }

  // Block the dashboard's `hermes update` action; CI marketplace updates Hermes via app images.
  // Match the parsed pathname so query strings cannot bypass the block.
  if (req.method === "POST" && requestPath === "/api/hermes/update") {
    blockHermesUpdate(req, res);
    return;
  }

  // Upstream documents separate dashboard/gateway containers, but this action
  // still shells out locally. In the CI app that would run from the web container
  // instead of restarting the gateway container managed by CI marketplace/Docker.
  if (req.method === "POST" && requestPath === "/api/gateway/restart") {
    blockGatewayRestart(req, res);
    return;
  }

  // In CI marketplace, request auth is enforced upstream by Traefik forward-auth.
  // Hermes dashboard's own /api/auth/me can return 401 without dashboard-local
  // auth state, which triggers noisy browser errors despite valid app access.
  if (req.method === "GET" && requestPath === "/api/auth/me") {
    handleCiAuthMe(req, res);
    return;
  }

  // Everything else proxied to dashboard (behind CI marketplace auth)
  proxyToDashboard(req, res);
});

// WebSocket server for the interactive terminal
const wss = new WebSocket.Server({ noServer: true });

wss.on("connection", (ws) => {
  console.log("Terminal WebSocket connected");

  clearPtyCleanupTimer();
  if (activeWs && activeWs !== ws && activeWs.readyState === WebSocket.OPEN) {
    try {
      activeWs.close(1000, "Replaced by a newer terminal tab");
    } catch (e) {}
  }
  activeWs = ws;
  startPtyIfNeeded();

  ws.on("message", (msg) => {
    try {
      // Ignore events from stale/replaced sockets.
      if (activeWs !== ws) {
        return;
      }
      const parsed = JSON.parse(msg);
      if (!ptyProcess) {
        return;
      }
      if (parsed.type === "input") {
        const cleaned = stripLeakedOscResponses(parsed.data);
        if (cleaned) {
          ptyProcess.write(cleaned);
        }
      } else if (parsed.type === "resize") {
        ptyProcess.resize(parsed.cols, parsed.rows);
      }
    } catch (e) {
      console.error("Error processing terminal input:", e.message);
    }
  });

  ws.on("close", () => {
    console.log("Terminal WebSocket closed");
    if (activeWs === ws) {
      activeWs = null;
      schedulePtyCleanup();
    }
  });
});

server.on("upgrade", (req, socket, head) => {
  try {
    let url;
    try {
      const hostHeader = String(req.headers.host || "");
      if (!hostHeader) {
        throw new Error("Missing Host header");
      }
      url = new URL(req.url, `http://${hostHeader}`);
    } catch (e) {
      socket.write("HTTP/1.1 400 Bad Request\r\n\r\n");
      socket.destroy();
      return;
    }

    if (url.pathname === "/ci/api/terminal") {
      // Validate anti-CSWSH token (byte-safe compare; see tokensMatch).
      const provided = url.searchParams.get("token") || "";
      const tokenValid = tokensMatch(provided, SETUP_TOKEN);

      const sameOrigin = isSameOriginUpgrade(req);

      const allowSameOriginFallback = ALLOW_SAME_ORIGIN_WS_FALLBACK && sameOrigin;
      if (!tokenValid && !allowSameOriginFallback) {
        socket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
        socket.destroy();
        return;
      }
      wss.handleUpgrade(req, socket, head, (ws) => {
        wss.emit("connection", ws, req);
      });
      return;
    }

    if (!isSameOriginUpgrade(req)) {
      socket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
      socket.destroy();
      return;
    }

    proxyDashboardUpgrade(req, socket, head);
  } catch (err) {
    // Defense in depth: never let an upgrade-handler throw escape as an uncaught
    // exception (which would crash the wrapper). Reject the socket and move on.
    console.error("[hermes] upgrade handler error:", err && err.message ? err.message : err);
    try {
      socket.destroy();
    } catch {
      /* socket already gone */
    }
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Hermes terminal server listening on port ${PORT}`);
});

// Last-resort backstop: keep a stray throw/rejection (e.g. from an event
// handler outside a request's try/catch) from hard-crashing the wrapper and
// dropping the whole app. Log and keep serving.
process.on("uncaughtException", (err) => {
  console.error("[hermes] uncaughtException:", err && err.stack ? err.stack : err);
});
process.on("unhandledRejection", (reason) => {
  console.error("[hermes] unhandledRejection:", reason);
});

// Graceful shutdown
process.on("SIGTERM", () => {
  console.log("Received SIGTERM, shutting down...");
  if (activeWs) {
    try {
      activeWs.close(1001, "Server shutting down");
    } catch (e) {}
    activeWs = null;
  }
  clearPtyCleanupTimer();
  killPty();
  server.close();
});
