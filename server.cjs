const http = require("http");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const pty = require("/app/node_modules/node-pty");
const WebSocket = require("/app/node_modules/ws");

const PORT = parseInt(process.env.PORT || "18789");
// Anti-CSWSH token: browsers don't enforce same-origin on WebSocket upgrades,
// so without this any site could connect to /ci/api/terminal and hijack the PTY.
// APP_SEED (per-app secret from CI marketplace) is embedded in the served HTML.
const SETUP_TOKEN = process.env.APP_SEED || "";
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
  // Remove optional :port suffix and lowercase for robust same-origin checks.
  return String(hostValue)
    .trim()
    .toLowerCase()
    .replace(/:\d+$/, "");
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
    '<a class="ci-terminal-shortcut" href="/terminal" aria-label="Open Hermes chat terminal">Open Chat</a>';

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

const server = http.createServer((req, res) => {
  const requestUrl = new URL(req.url || "/", "http://localhost");
  const requestPath = requestUrl.pathname.replace(/\/+$/, "");

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
    // Validate anti-CSWSH token.
    const provided = url.searchParams.get("token") || "";
    const providedBuffer = Buffer.from(provided);
    const tokenBuffer = Buffer.from(SETUP_TOKEN);
    const tokenValid =
      !!SETUP_TOKEN &&
      providedBuffer.length === tokenBuffer.length &&
      crypto.timingSafeEqual(providedBuffer, tokenBuffer);

    let sameOrigin = false;
    try {
      const origin = String(req.headers.origin || "");
      if (origin) {
        const originUrl = new URL(origin);
        const requestHostName = normalizeHostName(req.headers.host || "");
        const originHostName = normalizeHostName(originUrl.host || "");
        sameOrigin = !!requestHostName && requestHostName === originHostName;
      }
    } catch (e) {
      sameOrigin = false;
    }

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

  socket.end("HTTP/1.1 404 Not Found\r\n\r\n");
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Hermes terminal server listening on port ${PORT}`);
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
