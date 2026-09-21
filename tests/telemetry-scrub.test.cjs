const { afterEach, describe, test } = require("node:test");
const assert = require("node:assert/strict");

const {
  MAX_STRING_LENGTH,
  registerEnvSecrets,
  registerSecret,
  resetSecrets,
  scrubEvent,
  scrubString,
  scrubUrl,
  scrubValue,
} = require("../telemetry/scrub.cjs");
const { HERMES_SCRUB_CASES, SCRUB_CASES } = require("../telemetry/fixtures.cjs");

// ---------------------------------------------------------------------------
// beforeSend is the last thing that runs before a payload leaves this container,
// and this container has a live PTY into the user's data. Every case below was
// a confirmed leak in the first draft of the fleet's scrubber (CI-Server's
// adversarial review) or is specific to what this wrapper handles: terminal
// frames, the APP_SEED terminal token, and LLM provider keys.
// ---------------------------------------------------------------------------

afterEach(() => resetSecrets());

describe("scrubString: credentials", () => {
  test("redacts bearer tokens", () => {
    const scrubbed = scrubString("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc.def");

    assert.match(scrubbed, /\[Filtered\]/);
    assert.doesNotMatch(scrubbed, /eyJhbGciOiJIUzI1NiJ9/);
  });

  test("redacts labelled secrets in every spelling", () => {
    assert.doesNotMatch(scrubString("api_key=sk-live-1234567890"), /sk-live-1234567890/);
    assert.doesNotMatch(scrubString("api-key: sk-live-0987654321"), /sk-live-0987654321/);
    assert.doesNotMatch(scrubString("password: hunter2"), /hunter2/);
    assert.doesNotMatch(scrubString('{"token":"abcdef123456"}'), /abcdef123456/);
  });

  test("redacts tailscale auth keys", () => {
    assert.equal(scrubString("tskey-auth-abc123-def456"), "[Filtered]");
  });

  test("redacts credentials embedded in connection URLs", () => {
    const scrubbed = scrubString("postgres://ci:pgadmin_s3cure@db:5432/companion");

    assert.doesNotMatch(scrubbed, /pgadmin_s3cure/);
    assert.match(scrubbed, /\[Filtered\]/);
  });

  test("redacts bare LLM provider keys, which arrive with no label", () => {
    // Hermes sources OPENAI_/ANTHROPIC_/GEMINI_ credentials from the Hub
    // bootstrap env and hands them to the agent; a provider SDK that echoes the
    // key it was given produces exactly this shape.
    assert.doesNotMatch(scrubString("bad key sk-proj-AbCdEf0123456789XyZ"), /sk-proj-AbCdEf0123456789XyZ/);
    assert.doesNotMatch(scrubString("sk-ant-api03-0123456789abcdefghij"), /0123456789abcdefghij/);
    // Short `sk-` fragments are ordinary text, not credentials.
    assert.equal(scrubString("sk-abc"), "sk-abc");
  });
});

describe("scrubString: home paths leak the account name", () => {
  test("collapses macOS, Linux and Windows homes", () => {
    assert.equal(scrubString("/Users/liam/devel/ci/file.js"), "~/devel/ci/file.js");
    assert.equal(scrubString("/home/ci/data/timeline.db"), "~/data/timeline.db");
    assert.equal(scrubString("C:\\Users\\liam\\app.log"), "~\\app.log");
  });

  test("matches Windows before macOS, or a stranded `C:~/…` survives", () => {
    // Regression: the macOS rule used to match the `/Users/<name>` inside
    // `C:/Users/<name>` first, leaving the drive letter attached to `~`.
    assert.equal(scrubString("C:/Users/liam/AppData/ci"), "~/AppData/ci");
    assert.doesNotMatch(scrubString("C:/Users/liam/AppData/ci"), /C:/);
  });
});

describe("scrubString: bounds and inertness", () => {
  test("truncates oversized strings so scrollback cannot ride out in a message", () => {
    const scrubbed = scrubString("a".repeat(MAX_STRING_LENGTH + 1000));

    assert.equal(scrubbed.length, MAX_STRING_LENGTH + "… [truncated]".length);
    assert.ok(scrubbed.endsWith("… [truncated]"));
  });

  test("leaves ordinary text alone", () => {
    assert.equal(
      scrubString('Cannot read properties of undefined (reading "id")'),
      'Cannot read properties of undefined (reading "id")',
    );
  });
});

describe("scrubString: terminal frames (Hermes-specific)", () => {
  test("redacts the input slice V8 echoes back from a JSON.parse failure", () => {
    // Built from a real failure rather than a literal, so the test still holds
    // if V8 rewords the message: what matters is that the frame never survives.
    let message = "";
    try {
      JSON.parse('ssh deploy@prod "cat /etc/shadow"');
    } catch (err) {
      message = err.message;
    }

    // V8 echoes the first ~10 bytes — the start of whatever was typed or pasted.
    assert.ok(message.includes("ssh deploy"), "precondition: V8 echoes the input");
    assert.doesNotMatch(scrubString(message), /ssh deploy/);
  });

  test("keeps the failure recognisable after redacting it", () => {
    assert.equal(
      scrubString(`Unexpected token 'p', "ssh root@db" is not valid JSON`),
      "Unexpected token, [Filtered], is not valid JSON",
    );
  });
});

describe("registerSecret: values no pattern can recognise", () => {
  test("redacts a per-boot token wherever it appears", () => {
    const token = "a".repeat(64);
    registerSecret(token);

    assert.equal(scrubString(`POST /__ci_memory/skip t=${token}`), "POST /__ci_memory/skip t=[Filtered]");
  });

  test("picks credential-shaped values out of the environment", () => {
    registerEnvSecrets({
      APP_SEED: "f00dcafef00dcafef00dcafef00dcafe",
      HUB_MCP_API_KEY: "hub-mcp-key-0123456789",
      CI_SERVER_TOKEN: "memory-token-0123456789",
      GATEWAY_HEALTH_URL: "http://ci-hermes-gateway:8642",
      // The gateway's API key, handed to the web container so the dashboard's
      // health probe can authenticate (patches/enable_gateway_health_auth.py).
      API_SERVER_KEY: "gateway-api-key-0123456789",
    });

    // APP_SEED is the terminal secret: an attacker holding it gets the PTY. It
    // must not survive with a `token=` label (the pattern rule) or without one
    // (the registered-value rule) — the WebSocket upgrade URL uses the former,
    // a proxied header dump the latter.
    assert.doesNotMatch(scrubString("upgrade ?token=f00dcafef00dcafef00dcafef00dcafe"), /f00dcafe/);
    assert.equal(scrubString("seed f00dcafef00dcafef00dcafef00dcafe seen"), "seed [Filtered] seen");
    assert.doesNotMatch(scrubString("hub said hub-mcp-key-0123456789"), /hub-mcp-key/);
    assert.doesNotMatch(scrubString("memory-token-0123456789 rejected"), /memory-token/);
    assert.doesNotMatch(scrubString("Bearer gateway-api-key-0123456789"), /gateway-api-key/);
    // Not a credential: redacting it would corrupt useful diagnostics.
    assert.match(scrubString("dial http://ci-hermes-gateway:8642"), /ci-hermes-gateway:8642/);
  });

  test("ignores short values, which would corrupt unrelated text", () => {
    registerEnvSecrets({ APP_SEED: "dev" });

    assert.equal(scrubString("running in dev mode"), "running in dev mode");
  });

  test("treats registered values as literals, not patterns", () => {
    registerSecret("a+b(c)[d]|e.f*g?h");

    assert.equal(scrubString("value a+b(c)[d]|e.f*g?h here"), "value [Filtered] here");
    assert.equal(scrubString("value aXbXcXdXeXfXgXh here"), "value aXbXcXdXeXfXgXh here");
  });
});

describe("scrubValue: structures", () => {
  test("filters sensitive keys at any depth", () => {
    const scrubbed = scrubValue({
      outer: { password: "hunter2", note: "/home/ci/x" },
      dsn: "https://k@o1.ingest.sentry.io/2",
      "x-api-key": "ci_live_abcdef123456",
      app_seed: "f00dcafef00dcafe",
    });

    assert.equal(scrubbed.outer.password, "[Filtered]");
    assert.equal(scrubbed.outer.note, "~/x");
    assert.equal(scrubbed.dsn, "[Filtered]");
    assert.equal(scrubbed["x-api-key"], "[Filtered]");
    assert.equal(scrubbed.app_seed, "[Filtered]");
  });

  test("walks arrays and stops at a depth bound", () => {
    assert.deepEqual(scrubValue(["/home/ci/a", { token: "abc" }]), ["~/a", { token: "[Filtered]" }]);

    let deep = "leaf";
    for (let i = 0; i < 12; i += 1) {
      deep = { nested: deep };
    }
    assert.equal(JSON.stringify(scrubValue(deep)).includes("[Truncated]"), true);
  });

  test("survives a cyclic payload instead of hanging beforeSend", () => {
    const cyclic = { name: "loop" };
    cyclic.self = cyclic;

    assert.doesNotThrow(() => scrubValue(cyclic));
  });
});

describe("scrubEvent: message, exception and stack frames", () => {
  test("scrubs the message and exception values", () => {
    const scrubbed = scrubEvent({
      message: "failed for /Users/liam/notes",
      exception: { values: [{ value: "Bearer secrettokenvalue rejected" }] },
    });

    assert.equal(scrubbed.message, "failed for ~/notes");
    assert.doesNotMatch(scrubbed.exception.values[0].value, /secrettokenvalue/);
  });

  test("scrubs frame paths and captured locals, but keeps the path body", () => {
    const scrubbed = scrubEvent({
      exception: {
        values: [
          {
            value: "boom",
            stacktrace: {
              frames: [
                {
                  filename: "/Users/liam/devel/ci/server.cjs",
                  abs_path: "/Users/liam/devel/ci/server.cjs",
                  // In this wrapper, frame locals are terminal frames and tokens.
                  vars: { msg: '{"type":"input","data":"cat /home/ci/.ssh/id_ed25519"}', SETUP_TOKEN: "abc" },
                },
              ],
            },
          },
        ],
      },
    });

    const frame = scrubbed.exception.values[0].stacktrace.frames[0];

    // Home collapsed, rest of the path intact: Sentry groups issues on filename,
    // so redacting the body would destroy grouping.
    assert.equal(frame.filename, "~/devel/ci/server.cjs");
    assert.equal(frame.abs_path, "~/devel/ci/server.cjs");
    assert.equal(frame.vars.SETUP_TOKEN, "[Filtered]");
    assert.doesNotMatch(frame.vars.msg, /\/home\/ci/);
    // Note what this does NOT prove: arbitrary terminal text inside a captured
    // local matches no pattern and would survive. That is why the
    // LocalVariables integrations are dropped at init rather than relied on
    // being scrubbed here — see telemetry/index.cjs.
  });

  // `contextLinesIntegration` is a DEFAULT integration and `sendDefaultPii` does
  // not gate it: it reads the throwing file off disk and attaches the offending
  // line plus the lines either side. That is real program text — a hardcoded
  // provider key, a connection string with its password, a literal home path all
  // live there — and unlike `filename` these fields play no part in Sentry's
  // grouping, so there is nothing to preserve by leaving them alone.
  test("scrubs the source context around the throwing line", () => {
    const scrubbed = scrubEvent({
      exception: {
        values: [
          {
            value: "boom",
            stacktrace: {
              frames: [
                {
                  filename: "/Users/liam/devel/ci/server.cjs",
                  context_line: "  const key = 'sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAA';",
                  pre_context: ["  const db = 'postgres://ci:pgs3cure@db:5432/hermes';"],
                  post_context: ["  log('/Users/liam/secrets/notes.txt');"],
                },
              ],
            },
          },
        ],
      },
    });

    const frame = scrubbed.exception.values[0].stacktrace.frames[0];

    assert.doesNotMatch(frame.context_line, /sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAA/);
    assert.match(frame.context_line, /\[Filtered\]/);
    assert.doesNotMatch(frame.pre_context[0], /pgs3cure/);
    assert.doesNotMatch(frame.post_context[0], /\/Users\/liam/);
    // The frame's own path stays navigable — the grouping guarantee above is
    // not weakened by this.
    assert.equal(frame.filename, "~/devel/ci/server.cjs");
  });

  test("removes the machine hostname", () => {
    assert.equal(scrubEvent({ server_name: "hermes-household.local" }).server_name, undefined);
  });

  test("scrubs contexts, where NodeSystemError parks raw syscall details", () => {
    const scrubbed = scrubEvent({
      contexts: {
        node_system_error: { syscall: "open", path: "/home/ci/.env.hub-bootstrap", errno: -2 },
        runtime: { name: "node", version: "v22.22.3" },
      },
    });

    assert.equal(scrubbed.contexts.node_system_error.path, "~/.env.hub-bootstrap");
    assert.equal(scrubbed.contexts.node_system_error.errno, -2);
    assert.equal(scrubbed.contexts.runtime.version, "v22.22.3");
  });

  test("passes through an event with nothing to scrub", () => {
    assert.deepEqual(scrubEvent({ message: "plain failure" }), { message: "plain failure" });
  });
});

describe("scrubEvent: request data", () => {
  test("drops cookies and body, filters the query string", () => {
    const scrubbed = scrubEvent({
      request: {
        cookies: { ci_memory_deferred: "1" },
        data: { prompt: "what did I do last summer" },
        query_string: "token=f00dcafe",
        headers: { authorization: "Bearer abc", "user-agent": "curl/8" },
      },
    });

    assert.equal(scrubbed.request.cookies, undefined);
    assert.equal(scrubbed.request.data, undefined);
    assert.equal(scrubbed.request.query_string, "[Filtered]");
    assert.equal(scrubbed.request.headers.authorization, "[Filtered]");
    // Useful diagnostics survive.
    assert.equal(scrubbed.request.headers["user-agent"], "curl/8");
  });

  test("strips the query from request.url, not just query_string", () => {
    // The SDK builds request.url from req.url, which on a Node server is
    // path+query — filtering query_string alone would redact nothing. On this
    // wrapper the query on every terminal upgrade is the APP_SEED token.
    const scrubbed = scrubEvent({
      request: {
        url: "https://hermes.example.com/ci/api/terminal?token=f00dcafef00dcafe",
        query_string: "token=f00dcafef00dcafe",
      },
    });

    assert.equal(scrubbed.request.url, "https://hermes.example.com/ci/api/terminal");
    assert.doesNotMatch(JSON.stringify(scrubbed), /f00dcafef00dcafe/);
  });

  test("strips the query from URL-valued headers", () => {
    const scrubbed = scrubEvent({
      request: {
        headers: {
          Referer: "https://hermes.example.com/terminal?token=f00dcafef00dcafe",
          location: "/terminal?token=abc",
        },
      },
    });

    assert.equal(scrubbed.request.headers.Referer, "https://hermes.example.com/terminal");
    assert.equal(scrubbed.request.headers.location, "/terminal");
  });

  test("filters the hyphenated x-api-key header", () => {
    // sendDefaultPii:false does NOT stop request headers — this regex is the
    // only guard, and it has to match the hyphenated header spelling.
    const scrubbed = scrubEvent({ request: { headers: { "x-api-key": "ci_live_abcdef123456" } } });

    assert.equal(scrubbed.request.headers["x-api-key"], "[Filtered]");
  });

  test("filters CI-Hub's identity header, which carries the household username", () => {
    const scrubbed = scrubEvent({
      request: { headers: { "x-ci-hub-user": "liam", "x-ci-hub-user-signature": "abc" } },
    });

    assert.equal(scrubbed.request.headers["x-ci-hub-user"], "[Filtered]");
    assert.equal(scrubbed.request.headers["x-ci-hub-user-signature"], "[Filtered]");
  });

  test("filters generic signature headers, not just CI-Hub's", () => {
    // The CI-Hub triple was already covered, but only incidentally: `hub[-_]user`
    // is unanchored, so it matches `x-ci-hub-user-signature` on the *user* half.
    // A signature header that does not carry `hub-user` in its name matched no
    // rule at all and shipped in cleartext. An HMAC is a credential — it is the
    // proof-of-authenticity for a request body and replayable against the
    // verifier, so it is redacted like any other.
    const scrubbed = scrubEvent({
      request: {
        headers: {
          "x-hub-signature-256": "sha256=abc123",
          "x-webhook-signature": "deadbeef",
          Signature: "keyId=hermes,signature=abc",
          "user-agent": "curl/8",
        },
      },
    });

    assert.equal(scrubbed.request.headers["x-hub-signature-256"], "[Filtered]");
    assert.equal(scrubbed.request.headers["x-webhook-signature"], "[Filtered]");
    assert.equal(scrubbed.request.headers.Signature, "[Filtered]");
    // The header name is not a substring of anything diagnostic — ordinary
    // headers still survive alongside it.
    assert.equal(scrubbed.request.headers["user-agent"], "curl/8");
  });
});

describe("scrubEvent: breadcrumbs", () => {
  test("scrubs crumb messages and every data value", () => {
    const scrubbed = scrubEvent({
      breadcrumbs: [{ message: "GET /Users/liam", data: { token: "abc123", note: "/home/ci/x" } }],
    });

    assert.equal(scrubbed.breadcrumbs[0].message, "GET ~");
    assert.equal(scrubbed.breadcrumbs[0].data.token, "[Filtered]");
    assert.equal(scrubbed.breadcrumbs[0].data.note, "~/x");
  });

  test("treats url/from/to crumb data as URLs, query string and all", () => {
    // http/fetch breadcrumbs record the full URL. The wrapper's own Hub call
    // carries ?clientHost=<the household's public host>.
    const scrubbed = scrubEvent({
      breadcrumbs: [
        {
          category: "http",
          data: {
            url: "http://hub:3000/api/memory-connect/apps/urn/state?clientHost=liam.example.com",
            from: "/terminal?token=abc",
            to: "/?next=%2Fterminal%3Ftoken%3Dabc",
          },
        },
      ],
    });

    const data = scrubbed.breadcrumbs[0].data;

    assert.equal(data.url, "http://hub:3000/api/memory-connect/apps/urn/state");
    assert.equal(data.from, "/terminal");
    assert.equal(data.to, "/");
  });
});

describe("scrubEvent: robustness", () => {
  test("tolerates the shapes a malformed event can take", () => {
    assert.doesNotThrow(() => scrubEvent({}));
    assert.doesNotThrow(() => scrubEvent({ exception: { values: [{}] } }));
    assert.doesNotThrow(() => scrubEvent({ breadcrumbs: [{}] }));
    assert.doesNotThrow(() => scrubEvent({ request: {} }));
    assert.equal(scrubEvent(null), null);
  });
});

describe("shared scrub fixtures (drift guard)", () => {
  // The same list is carried by every copy of the scrubber in the fleet. A rule
  // added here but not there (or vice versa) means the copies have drifted.
  for (const testCase of SCRUB_CASES) {
    test(testCase.name, () => {
      const actual = scrubString(testCase.input);

      if (testCase.expected !== undefined) {
        assert.equal(actual, testCase.expected);
      }

      for (const forbidden of testCase.mustNotContain || []) {
        assert.ok(!actual.includes(forbidden), `"${forbidden}" survived scrubbing`);
      }
    });
  }

  test("the Hermes-specific cases are part of the shared list", () => {
    for (const testCase of HERMES_SCRUB_CASES) {
      assert.ok(
        SCRUB_CASES.some((entry) => entry.name === testCase.name),
        `${testCase.name} is missing from SCRUB_CASES`,
      );
    }
  });
});

describe("scrubUrl", () => {
  test("drops query and hash without touching the path", () => {
    assert.equal(scrubUrl("/ci/api/terminal?token=abc#frag"), "/ci/api/terminal");
    assert.equal(scrubUrl("https://h.example.com/a/b"), "https://h.example.com/a/b");
    assert.equal(scrubUrl("not a url"), "not a url");
  });
});
