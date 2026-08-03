/**
 * Redaction cases every copy of the CI scrubber must handle identically.
 *
 * The fleet has one scrubber per language/build graph (CI-Server's
 * `common/telemetry/scrubEvent.ts` and its Python twins, CI-Import-Tools,
 * Companion-Planning, and this one), and nothing is shared between them at
 * build time. This list is the drift guard: an adversarial review of the first
 * draft found the browser copy shipping with NONE of the string rules, which a
 * parity check would have caught first.
 *
 * Expressed as string -> string so any copy can consume it without importing an
 * SDK type. The Hermes-specific cases at the end are additions, not deviations:
 * they cover the secrets and payloads this wrapper actually handles.
 */

/** Cases shared with the rest of the fleet — keep in lockstep. */
const SHARED_SCRUB_CASES = [
  {
    name: "bearer token",
    input: "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc.def",
    mustNotContain: ["eyJhbGciOiJIUzI1NiJ9"],
  },
  {
    name: "labelled api key",
    input: "api_key=sk-live-1234567890",
    mustNotContain: ["sk-live-1234567890"],
  },
  {
    name: "hyphenated api key",
    input: "api-key: sk-live-0987654321",
    mustNotContain: ["sk-live-0987654321"],
  },
  {
    name: "labelled password",
    input: "password: hunter2",
    mustNotContain: ["hunter2"],
  },
  {
    name: "tailscale auth key",
    input: "tskey-auth-abc123-def456",
    expected: "[Filtered]",
  },
  {
    name: "credentials in a connection URL",
    input: "postgres://ci:pgadmin_s3cure@db:5432/companion",
    mustNotContain: ["pgadmin_s3cure"],
  },
  {
    name: "macOS home path",
    input: "/Users/liam/devel/ci/file.ts",
    expected: "~/devel/ci/file.ts",
  },
  {
    name: "Linux home path",
    input: "/home/ci/data/timeline.db",
    expected: "~/data/timeline.db",
  },
  {
    name: "Windows home path, backslash",
    input: "C:\\Users\\liam\\app.log",
    expected: "~\\app.log",
  },
  {
    // Regression: the macOS rule used to match inside this and leave `C:~/…`.
    name: "Windows home path, forward slash",
    input: "C:/Users/liam/AppData/ci",
    expected: "~/AppData/ci",
  },
  {
    name: "ordinary text is untouched",
    input: 'Cannot read properties of undefined (reading "id")',
    expected: 'Cannot read properties of undefined (reading "id")',
  },
];

/**
 * Cases specific to this wrapper.
 *
 * Hermes shuttles LLM provider credentials (the `OPENAI_`/`ANTHROPIC_`/`GEMINI_`
 * prefixed values it sources from the Hub bootstrap env) and its terminal
 * WebSocket carries the user's raw keystrokes, so both get their own rules.
 */
const HERMES_SCRUB_CASES = [
  {
    name: "bare OpenAI-style provider key",
    input: "provider rejected sk-proj-AbCdEf0123456789XyZ",
    mustNotContain: ["sk-proj-AbCdEf0123456789XyZ"],
  },
  {
    name: "bare Anthropic-style provider key",
    input: "sk-ant-api03-0123456789abcdefghij",
    mustNotContain: ["sk-ant-api03-0123456789abcdefghij"],
  },
  {
    name: "terminal frame echoed by a JSON.parse failure",
    // V8 embeds up to ~30 raw bytes of the offending input in this message. On
    // this app that input is a terminal frame: the user's keystrokes.
    input: `Unexpected token 'p', "ssh root@prod-db" is not valid JSON`,
    mustNotContain: ["ssh root@prod-db"],
  },
  {
    name: "terminal WebSocket URL carrying the APP_SEED token",
    input: "GET /ci/api/terminal?token=f00dcafef00dcafef00dcafef00dcafe failed",
    mustNotContain: ["f00dcafef00dcafef00dcafef00dcafe"],
  },
];

const SCRUB_CASES = [...SHARED_SCRUB_CASES, ...HERMES_SCRUB_CASES];

/** Strings longer than this must be truncated by every copy. */
const MAX_STRING_LENGTH = 8000;

module.exports = {
  HERMES_SCRUB_CASES,
  MAX_STRING_LENGTH,
  SCRUB_CASES,
  SHARED_SCRUB_CASES,
};
