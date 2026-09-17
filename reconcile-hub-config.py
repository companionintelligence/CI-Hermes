#!/usr/bin/env python3
"""Make the Hub-managed inference settings in config.yaml follow the Hub handout.

The Hub hands CI-Hermes its inference settings as a dotenv body
(GET $CI_HUB_URL/api/inference/apps/hermes-agent/bootstrap.env), which
bootstrap-from-hub.sh writes to $HERMES_HOME/.env.hub-bootstrap. This script is
the ONE place that turns that handout into config.yaml, on every start:

  model.default / model.base_url / model.api_key   the main model and endpoint
  model.ollama_num_ctx / model.context_length      the hardware-sized window
  providers.ollama                                 the GUI model picker entry
  auxiliary.<task>                                 side-task routing

config.yaml is the single source of truth for these. The upstream runtime ranks
env CUSTOM_BASE_URL over model.base_url and HERMES_INFERENCE_MODEL over
model.default, so bootstrap-from-hub.sh no longer exports those for a Hub endpoint
config.yaml carries (see hub-env.sh), and a change here reaches every process —
dashboard, gateway, terminal — through Hermes' own mtime-cached config reload.

Why this exists: the handout used to reach config.yaml only when the file was first
generated. core-4 ran for weeks on a first-boot gemma3:1b pointed straight at host
Ollama (32,768-token window, below Hermes' 64,000 minimum) after the Hub had moved
the app to the pool with qwen3-coder:30b.

Ownership. A value this script wrote is recorded in $HERMES_HOME/.hub-managed-config.json.
On the next start a config value that still equals its record is Hub-managed and
follows the new handout; a value that differs was changed by someone else — a GUI
model switch, a hand edit — and is kept, with a log line saying so. The record lives
beside config.yaml rather than as YAML comments because Hermes rewrites config.yaml
with yaml.dump on every GUI change, which strips comments.

  Installs that predate the record are adopted from the shape of what earlier
  versions of this bootstrap wrote: a providers.ollama entry named 'Ollama (local)'
  (a string nothing else writes) whose base_url the model block and auxiliary tasks
  still share. Anything that does not match that shape is left to the user.

The context window (ollama_num_ctx / context_length) keeps its existing contract:
it is sized by the Hub for this hardware and always follows the handout.

A cloud handout does not replace a Hub endpoint already in config.yaml. The Hub hands
out its first enabled cloud provider whenever local inference is unhealthy at the
moment the app fetches — an Ollama restart during an app restart is enough — and
switching on that would move every conversation to a paid provider until the next
restart. It is logged instead. (Upstream resolves `provider: ollama` through the
providers.ollama entry, so such a handout never took effect before either.) An install
that has only ever had a cloud handout keeps following its model, as it always has,
with the endpoint and key in env.

A handout below Hermes' 64K minimum is refused: when the Hub switches a working
Hub-managed model to one whose window cannot satisfy the minimum, the previous model
is kept. Either way the problem is written to $HERMES_HOME/.hub-inference-warning,
which the web terminal prints, and to the container log.

Stdlib only. PyYAML, when importable (it is in the image), validates the result
before anything is written. Writes are atomic and serialized with a lock, because
the web and gateway containers share /opt/data and start at the same time.
"""

import argparse
import errno
import json
import os
import re
import stat
import sys
import tempfile
import time
from pathlib import Path

try:
    import fcntl
except ImportError:  # pragma: no cover - containers are Linux
    fcntl = None

# Upstream MINIMUM_CONTEXT_LENGTH: the literal 64000 (not 65536), compared with a
# strict `<`, so exactly 64000 is accepted.
HERMES_MIN_CONTEXT = 64000
LOCAL_API_KEY = "ollama"
PICKER_NAME = "Ollama (local)"
AUX_TASKS = (
    "compression",
    "title_generation",
    "vision",
    "web_extract",
    "session_search",
    "skills_hub",
    "mcp",
)

# model.provider values the Hub's settings apply to: the upstream aliases that resolve
# to the "custom" runtime (the one that honours model.base_url and ollama_num_ctx),
# plus the mislabels an earlier GUI switch left on the local endpoint. Any other
# provider was chosen by the user, and the model block is theirs.
HUB_PROVIDERS = {"", "auto", "custom", "ollama", "vllm", "llamacpp", "llama-cpp", "lmstudio", "lm-studio"}
MISLABELED_LOCAL_PROVIDERS = {"openai-api", "openai"}

STATE_FILE = ".hub-managed-config.json"
WARNING_FILE = ".hub-inference-warning"
LOCK_FILE = ".hub-config.lock"
STATE_SCHEMA = 1


def log(msg: str) -> None:
    print(f"[hub-config] {msg}", flush=True)


# ── Handout ───────────────────────────────────────────────────────────────────


def read_dotenv(path: Path) -> dict:
    env = {}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return env
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip("\r")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        env[key.strip()] = value
    return env


class Handout:
    def __init__(self, env: dict, native: bool):
        self.base_url = env.get("HERMES_OPENAI_BASE_URL", "").strip()
        api_key = env.get("HERMES_OPENAI_API_KEY", "").strip()
        self.model = (
            env.get("HERMES_DEFAULT_MODEL", "").strip()
            or env.get("HERMES_DEFAULT_MODEL_BACKEND_ID", "").strip()
        )
        raw_ctx = re.sub(r"[\s\"']", "", env.get("HERMES_NUM_CTX", ""))
        self.num_ctx = int(raw_ctx) if re.fullmatch(r"[1-9][0-9]*", raw_ctx) else None
        # "local": the Hub's own endpoint (the "ollama" key sentinel — direct Ollama
        #   or the pool proxy in front of it). config.yaml carries the endpoint.
        # "remote": any other endpoint with a real credential (a cloud provider).
        #   The key never goes into config.yaml, so the endpoint stays in env.
        # "none": the handout names no endpoint.
        if self.base_url and api_key == LOCAL_API_KEY:
            self.kind = "local"
        elif self.base_url:
            self.kind = "remote"
        else:
            self.kind = "none"
        self.native = native

    @property
    def below_minimum(self) -> bool:
        return self.num_ctx is not None and self.num_ctx < HERMES_MIN_CONTEXT

    @property
    def empty(self) -> bool:
        return self.kind == "none" and not self.model and self.num_ctx is None


# ── Line-level YAML editing ───────────────────────────────────────────────────
# Line edits, not a load/dump round trip, so a user's comments and layout survive
# every start. Scope is the fixed two/three-level shapes this file manages, at
# the 2-space indentation both this bootstrap and Hermes' yaml.dump produce.


def parse_scalar(raw: str) -> str:
    """The string value of a YAML scalar as written on one line."""
    s = raw.strip()
    if s.startswith("'"):
        out, i = [], 1
        while i < len(s):
            if s[i] == "'":
                if i + 1 < len(s) and s[i + 1] == "'":
                    out.append("'")
                    i += 2
                    continue
                return "".join(out)
            out.append(s[i])
            i += 1
        return "".join(out)
    if s.startswith('"'):
        out, i = [], 1
        while i < len(s):
            c = s[i]
            if c == "\\" and i + 1 < len(s):
                out.append({"n": "\n", "t": "\t"}.get(s[i + 1], s[i + 1]))
                i += 2
                continue
            if c == '"':
                return "".join(out)
            out.append(c)
            i += 1
        return "".join(out)
    # Plain scalar: a comment starts at " #".
    s = re.split(r"\s+#", s, maxsplit=1)[0].strip()
    return s


def quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


class Plain(str):
    """A value written unquoted (identifiers like a provider slug)."""


def fmt(value) -> str:
    return str(value) if isinstance(value, (int, Plain)) else quote(value)


class Doc:
    def __init__(self, text: str):
        self.lines = text.splitlines(keepends=True)

    def text(self) -> str:
        return "".join(self.lines)

    # top level ------------------------------------------------------------
    def _top(self, name: str):
        rx = re.compile(rf"^{re.escape(name)}:(.*)$")
        for i, line in enumerate(self.lines):
            m = rx.match(line.rstrip("\n"))
            if m:
                return i, m.group(1)
        return None, None

    def section(self, name: str):
        """(start, end) of a block-form top-level section; None if absent or inline."""
        i, rest = self._top(name)
        if i is None:
            return None
        if rest.strip() and not rest.strip().startswith("#"):
            return None
        end = len(self.lines)
        for j in range(i + 1, len(self.lines)):
            line = self.lines[j]
            if line.strip() and not line.startswith((" ", "\t", "#")):
                end = j
                break
        return i, end

    def has_top(self, name: str) -> bool:
        return self._top(name)[0] is not None

    def open_inline_empty(self, name: str) -> bool:
        """Turn `name: {}` / `name: []` (a yaml.dump of an empty mapping) into a block."""
        i, rest = self._top(name)
        if i is not None and re.fullmatch(r"\s*(\{\s*\}|\[\s*\])\s*(#.*)?", rest):
            self.lines[i] = f"{name}:\n"
            return True
        return False

    def insert(self, at: int, new_lines) -> None:
        if at > 0 and not self.lines[at - 1].endswith("\n"):
            self.lines[at - 1] += "\n"
        self.lines[at:at] = list(new_lines)

    def add_section(self, name: str) -> None:
        tail = ["\n"] if self.lines and self.lines[-1].strip() else []
        self.insert(len(self.lines), tail + [f"{name}:\n"])

    @staticmethod
    def _content_end(lines, start: int, end: int) -> int:
        """Index just past the last non-blank line in lines[start:end]."""
        last = start
        for j in range(start, end):
            if lines[j].strip():
                last = j + 1
        return last

    # depth 2: `  child: value` -------------------------------------------
    def _child(self, section: str, child: str):
        span = self.section(section)
        if span is None:
            return None
        rx = re.compile(rf"^  {re.escape(child)}:(.*)$")
        for j in range(span[0] + 1, span[1]):
            m = rx.match(self.lines[j].rstrip("\n"))
            if m:
                return j, m.group(1)
        return None

    def get2(self, section: str, child: str):
        hit = self._child(section, child)
        if hit is None:
            return None
        value = parse_scalar(hit[1])
        return value if value != "" else None

    def set2(self, section: str, child: str, value) -> None:
        new = f"  {child}: {fmt(value)}\n"
        hit = self._child(section, child)
        if hit is not None:
            self.lines[hit[0]] = new
            return
        span = self.section(section)
        if span is None:
            self.open_inline_empty(section) or self.add_section(section)
            span = self.section(section)
        self.insert(self._content_end(self.lines, span[0] + 1, span[1]), [new])

    def del2(self, section: str, child: str) -> bool:
        removed = False
        while True:
            hit = self._child(section, child)
            if hit is None:
                return removed
            del self.lines[hit[0]]
            removed = True

    # depth 3: `  child:` block with `    leaf: value` -------------------
    def _block(self, section: str, child: str):
        span = self.section(section)
        if span is None:
            return None
        rx = re.compile(rf"^  {re.escape(child)}:\s*(#.*)?$")
        for j in range(span[0] + 1, span[1]):
            if rx.match(self.lines[j].rstrip("\n")):
                end = span[1]
                for k in range(j + 1, span[1]):
                    line = self.lines[k]
                    if line.strip() and not line.startswith("    ") and not line.lstrip().startswith("#"):
                        end = k
                        break
                return j, end
        return None

    def has_block(self, section: str, child: str) -> bool:
        return self._block(section, child) is not None

    def get3(self, section: str, child: str, leaf: str):
        block = self._block(section, child)
        if block is None:
            return None
        rx = re.compile(rf"^    {re.escape(leaf)}:(.*)$")
        for j in range(block[0] + 1, block[1]):
            m = rx.match(self.lines[j].rstrip("\n"))
            if m:
                value = parse_scalar(m.group(1))
                return value if value != "" else None
        return None

    def set3(self, section: str, child: str, leaf: str, value) -> None:
        new = f"    {leaf}: {fmt(value)}\n"
        block = self._block(section, child)
        if block is None:
            span = self.section(section)
            if span is None:
                self.open_inline_empty(section) or self.add_section(section)
                span = self.section(section)
            self.insert(self._content_end(self.lines, span[0] + 1, span[1]), [f"  {child}:\n", new])
            return
        rx = re.compile(rf"^    {re.escape(leaf)}:(.*)$")
        for j in range(block[0] + 1, block[1]):
            if rx.match(self.lines[j].rstrip("\n")):
                self.lines[j] = new
                return
        self.insert(self._content_end(self.lines, block[0] + 1, block[1]), [new])



# ── Paths ─────────────────────────────────────────────────────────────────────


def get_path(doc: Doc, path: str):
    parts = path.split(".")
    if len(parts) == 2:
        return doc.get2(*parts)
    return doc.get3(*parts)


def set_path(doc: Doc, path: str, value) -> None:
    parts = path.split(".")
    if len(parts) == 2:
        doc.set2(parts[0], parts[1], value)
    else:
        doc.set3(parts[0], parts[1], parts[2], value)


def shown(path: str, value) -> str:
    """A value safe for the log. api_key values are only ever the local sentinel when
    this script writes them, but a user's own may be a real credential."""
    if value is None:
        return "(unset)"
    if path.endswith("api_key") and value != LOCAL_API_KEY:
        return "<user credential>"
    return repr(value)


# ── Ownership record ──────────────────────────────────────────────────────────


def load_state(path: Path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        log(f"WARN: {path.name} unreadable ({exc.__class__.__name__}); re-adopting from config.yaml")
        return None
    managed = data.get("managed") if isinstance(data, dict) else None
    if not isinstance(managed, dict):
        log(f"WARN: {path.name} has no 'managed' map; re-adopting from config.yaml")
        return None
    return {str(k): str(v) for k, v in managed.items() if isinstance(v, (str, int))}


def adopt_legacy(doc: Doc) -> dict:
    """Infer what an earlier version of this bootstrap wrote, for an install that has
    no ownership record yet. Only values matching that exact shape are adopted."""
    state = {}
    if doc.get3("providers", "ollama", "name") != PICKER_NAME:
        return state
    picker_base = doc.get3("providers", "ollama", "base_url")
    state["providers.ollama.name"] = PICKER_NAME
    if picker_base:
        state["providers.ollama.base_url"] = picker_base
    if doc.get3("providers", "ollama", "api_key") == LOCAL_API_KEY:
        state["providers.ollama.api_key"] = LOCAL_API_KEY
    if not picker_base:
        return state

    ours = [
        t
        for t in AUX_TASKS
        if doc.get3("auxiliary", t, "base_url") == picker_base
        and doc.get3("auxiliary", t, "api_key") == LOCAL_API_KEY
    ]
    aux_models = [m for m in (doc.get3("auxiliary", t, "model") for t in ours) if m]
    # Every task was written with the same model; that is the Hub's model at the time.
    hub_model = max(set(aux_models), key=aux_models.count) if aux_models else None
    for t in ours:
        state[f"auxiliary.{t}.base_url"] = picker_base
        state[f"auxiliary.{t}.api_key"] = LOCAL_API_KEY
        if hub_model and doc.get3("auxiliary", t, "model") == hub_model:
            state[f"auxiliary.{t}.model"] = hub_model

    if doc.get2("model", "base_url") == picker_base:
        state["model.base_url"] = picker_base
        if doc.get2("model", "api_key") == LOCAL_API_KEY:
            state["model.api_key"] = LOCAL_API_KEY
        current = doc.get2("model", "default")
        # With side-task routing on, the tasks carry the Hub's model, so a GUI model
        # switch is distinguishable from a stale Hub default. Without it, the model
        # block still pointing at the Hub endpoint is the best evidence there is.
        if current and (hub_model is None or current == hub_model):
            state["model.default"] = current
    return state


# ── Reconcile ─────────────────────────────────────────────────────────────────


class Reconciler:
    def __init__(self, doc: Doc, state: dict):
        self.doc = doc
        self.state = state
        self.changes = []
        self.kept = []

    def want(self, path: str, value, create: bool = True) -> None:
        """Converge `path` on `value` if the Hub owns it. create=False leaves an absent
        key absent (used inside blocks a user may have written)."""
        current = get_path(self.doc, path)
        target = str(value)
        if current is None:
            if not create:
                return
            set_path(self.doc, path, value)
            self.state[path] = target
            self.changes.append(f"set {path}={shown(path, target)}")
        elif current == target:
            self.state[path] = target
        elif self.state.get(path) == current:
            set_path(self.doc, path, value)
            self.state[path] = target
            self.changes.append(f"{path}: {shown(path, current)} -> {shown(path, target)}")
        else:
            self.kept.append(
                f"kept user-set {path}={shown(path, current)} (Hub handout: {shown(path, target)})"
            )


def model_owned_by_hub(doc: Doc, state: dict) -> bool:
    current = doc.get2("model", "default")
    return current is not None and state.get("model.default") == current


def below_minimum_warning(h: Handout, previous, in_use, refused: bool) -> str:
    subject = f"model {h.model!r}" if h.model else "its model"
    text = (
        f"The Hub (Settings -> AI) hands Hermes {subject} with a {h.num_ctx}-token "
        f"context window, below Hermes' {HERMES_MIN_CONTEXT}-token minimum. "
    )
    if refused:
        text += (
            f"CI-Hermes kept the previous Hub model {previous!r} instead of switching "
            f"to one Hermes cannot start. "
        )
    elif h.model and in_use is not None and in_use != h.model:
        text += (
            f"Hermes keeps using your own model setting {in_use!r}, but the Hub-sized "
            f"context window still applies. "
        )
    else:
        text += "Hermes will refuse to start a session with it. "
    return text + (
        f"Choose a model with at least a {HERMES_MIN_CONTEXT}-token window in "
        f"Hub -> Settings -> AI, then restart Hermes from the Hub."
    )


def hub_endpoint_in_config(doc: Doc, state: dict) -> bool:
    """config.yaml still carries a Hub-written local endpoint."""
    return any(
        state.get(path) is not None and get_path(doc, path) == state[path]
        for path in ("providers.ollama.base_url", "model.base_url")
    )


def reconcile(doc: Doc, state: dict, h: Handout):
    r = Reconciler(doc, state)

    if h.kind == "remote" and hub_endpoint_in_config(doc, state):
        r.kept.append(
            "WARN: the Hub handed out a cloud provider, which it does when its local inference "
            "is unavailable as Hermes starts. config.yaml keeps the Hub's local endpoint and "
            "model rather than moving every conversation to a paid provider; restart Hermes "
            "from the Hub once local inference is back, or pick a provider in the Hermes model picker."
        )
        return r, None

    if h.below_minimum:
        current = doc.get2("model", "default")
        switching = bool(h.model) and current is not None and current != h.model
        if switching and model_owned_by_hub(doc, state):
            # Keep the whole last-known-good handout: model, endpoint and window
            # belong together, and the old model may not exist on a new endpoint.
            return r, below_minimum_warning(h, current, current, refused=True)

    model_section = doc.section("model") is not None
    if not model_section and h.model:
        if doc.has_top("model"):
            log("WARN: config.yaml has a non-block 'model:' value; leaving the model settings alone")
        else:
            doc.set2("model", "provider", Plain("ollama"))
            model_section = True

    provider = (doc.get2("model", "provider") or "").strip().lower() if model_section else ""
    if model_section and h.kind == "local" and provider in MISLABELED_LOCAL_PROVIDERS:
        # An earlier GUI switch mislabels the local endpoint as the OpenAI provider,
        # which drops num_ctx and targets api.openai.com.
        doc.set2("model", "provider", Plain("ollama"))
        r.changes.append(f"model.provider: {provider!r} -> 'ollama' (local endpoint)")
        provider = "ollama"
    if model_section and provider not in HUB_PROVIDERS:
        r.kept.append(
            f"kept user-set model.provider={provider!r}: its model, endpoint and window are not the Hub's to change"
        )
        model_section = False

    if model_section:
        if h.model:
            r.want("model.default", h.model)
        if h.kind == "local":
            r.want("model.base_url", h.base_url)
            r.want("model.api_key", LOCAL_API_KEY)

        if h.num_ctx is not None:
            if doc.del2("model", "num_ctx"):
                r.changes.append("removed legacy model.num_ctx (upstream reads ollama_num_ctx)")
            if doc.get2("model", "ollama_num_ctx") != str(h.num_ctx):
                doc.set2("model", "ollama_num_ctx", h.num_ctx)
                r.changes.append(f"model.ollama_num_ctx={h.num_ctx}")
            if h.num_ctx >= HERMES_MIN_CONTEXT:
                if doc.get2("model", "context_length") != str(h.num_ctx):
                    doc.set2("model", "context_length", h.num_ctx)
                    r.changes.append(f"model.context_length={h.num_ctx}")
            elif doc.del2("model", "context_length"):
                r.changes.append("removed model.context_length (Hub window below the minimum)")
    elif doc.section("model") is None and (h.kind == "local" or h.num_ctx is not None):
        log("no model section in config.yaml yet; the model settings follow once the Hub names a model")

    if h.kind == "local":
        reconcile_picker(doc, r, h)
        reconcile_aux(doc, r, h)

    warning = None
    if h.below_minimum:
        warning = below_minimum_warning(h, None, doc.get2("model", "default"), refused=False)
    return r, warning


def reconcile_picker(doc: Doc, r: Reconciler, h: Handout) -> None:
    """providers.ollama. Upstream resolves `model.provider: ollama` through this named
    entry — its base_url is the endpoint every process actually uses, ahead of
    model.base_url and env CUSTOM_BASE_URL — and the dashboard's model picker lists it.
    Keyed "ollama", an alias of the num_ctx-aware custom profile."""
    if doc.open_inline_empty("providers"):
        pass
    elif doc.has_top("providers") and doc.section("providers") is None:
        log("WARN: config.yaml has a non-block 'providers:' value; not registering the local endpoint")
        return
    if not doc.has_block("providers", "ollama"):
        doc.set3("providers", "ollama", "name", PICKER_NAME)
        doc.set3("providers", "ollama", "base_url", h.base_url)
        doc.set3("providers", "ollama", "api_key", LOCAL_API_KEY)
        r.state.update(
            {
                "providers.ollama.name": PICKER_NAME,
                "providers.ollama.base_url": h.base_url,
                "providers.ollama.api_key": LOCAL_API_KEY,
            }
        )
        r.changes.append(f"registered providers.ollama -> {h.base_url}")
        return
    # Only an entry this bootstrap created is ours to update or complete.
    if r.state.get("providers.ollama.name") != doc.get3("providers", "ollama", "name"):
        return
    r.want("providers.ollama.base_url", h.base_url)
    r.want("providers.ollama.api_key", LOCAL_API_KEY)


def reconcile_aux(doc: Doc, r: Reconciler, h: Handout) -> None:
    """Point side-tasks at the same endpoint as the main model. Hermes' aux
    auto-detection only tries cloud providers, so on a local-only appliance
    compression/title silently never run. The section is created only with native
    Ollama routing on (the flag keeps "off" a true no-op); tasks it created keep
    following the handout either way."""
    if not doc.has_top("auxiliary"):
        if not h.native:
            return
        for t in AUX_TASKS:
            doc.set3("auxiliary", t, "base_url", h.base_url)
            doc.set3("auxiliary", t, "api_key", LOCAL_API_KEY)
            r.state[f"auxiliary.{t}.base_url"] = h.base_url
            r.state[f"auxiliary.{t}.api_key"] = LOCAL_API_KEY
            if h.model:
                doc.set3("auxiliary", t, "model", h.model)
                r.state[f"auxiliary.{t}.model"] = h.model
        r.changes.append(f"added auxiliary side-task routing -> {h.base_url}")
        return
    for t in AUX_TASKS:
        if not doc.has_block("auxiliary", t):
            continue
        # A task is ours only if its endpoint is: never inject into a user's task.
        if r.state.get(f"auxiliary.{t}.base_url") is None:
            continue
        r.want(f"auxiliary.{t}.base_url", h.base_url, create=False)
        r.want(f"auxiliary.{t}.api_key", LOCAL_API_KEY, create=False)
        if h.model and r.state.get(f"auxiliary.{t}.base_url") == h.base_url:
            r.want(f"auxiliary.{t}.model", h.model, create=False)


# ── I/O ───────────────────────────────────────────────────────────────────────


class Lock:
    def __init__(self, path: Path, timeout: float = 30.0):
        self.path, self.timeout, self.fh = path, timeout, None

    def __enter__(self):
        if fcntl is None:
            return self
        self.fh = open(self.path, "a+")
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError as exc:
                if exc.errno not in (errno.EAGAIN, errno.EACCES) or time.monotonic() > deadline:
                    log(f"WARN: could not lock {self.path.name} ({exc}); continuing unlocked")
                    return self
                time.sleep(0.1)

    def __exit__(self, *exc):
        if self.fh is not None:
            try:
                fcntl.flock(self.fh, fcntl.LOCK_UN)
            finally:
                self.fh.close()


def atomic_write(path: Path, text: str, mode: int = 0o600) -> None:
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
    except FileNotFoundError:
        pass
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def validate(text: str, doc_before_ok: bool) -> bool:
    """Refuse to write YAML that no longer parses. Skipped without PyYAML, and when
    the file did not parse before we touched it (not ours to judge)."""
    if not doc_before_ok:
        return True
    try:
        import yaml
    except ImportError:
        return True
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        log(f"ERROR: reconciled config.yaml would not parse ({exc.__class__.__name__}); not writing it")
        return False
    if data is not None and not isinstance(data, dict):
        log("ERROR: reconciled config.yaml is not a mapping; not writing it")
        return False
    return True


def parses(text: str) -> bool:
    try:
        import yaml
    except ImportError:
        return True
    try:
        yaml.safe_load(text)
        return True
    except yaml.YAMLError:
        return False


def truthy(value: str) -> bool:
    return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def run(data_dir: Path) -> int:
    config_path = data_dir / "config.yaml"
    env_path = data_dir / ".env.hub-bootstrap"
    state_path = data_dir / STATE_FILE
    warning_path = data_dir / WARNING_FILE

    if not env_path.is_file():
        return 0
    h = Handout(read_dotenv(env_path), truthy(os.environ.get("CI_HERMES_OLLAMA_NATIVE", "")))
    if h.empty:
        return 0

    with Lock(data_dir / LOCK_FILE):
        try:
            before = config_path.read_text(encoding="utf-8")
            generated = False
        except FileNotFoundError:
            if not h.model:
                # Nothing to run yet; generating a model-less file would make Hermes
                # think a provider is configured.
                return 0
            before = ""
            generated = True

        doc = Doc(before)
        recorded = load_state(state_path)
        adopted = recorded is None and not generated
        state = dict(recorded) if recorded is not None else (adopt_legacy(doc) if adopted else {})
        if adopted and state:
            log(f"adopted {len(state)} Hub-written value(s) from an install that predates {STATE_FILE}")

        r, warning = reconcile(doc, state, h)
        after = doc.text()

        if after != before:
            if not validate(after, parses(before)):
                return 1
            atomic_write(config_path, after)
            verb = "wrote" if generated else "updated"
            log(f"{verb} {config_path} from the Hub handout: " + "; ".join(r.changes or ["generated"]))
        for line in r.kept:
            log(line)

        new_state = {"schema": STATE_SCHEMA, "managed": dict(sorted(r.state.items()))}
        if new_state["managed"] != (recorded or {}) or recorded is None:
            atomic_write(state_path, json.dumps(new_state, indent=2) + "\n")

        if warning:
            for line in ("=" * 72, f"ERROR: {warning}", "=" * 72):
                log(line)
            if not warning_path.is_file() or warning_path.read_text(encoding="utf-8") != warning + "\n":
                atomic_write(warning_path, warning + "\n", 0o644)
        elif warning_path.exists():
            warning_path.unlink()
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--data-dir",
        default=os.environ.get("HERMES_HOME") or "/opt/data",
        help="Hermes data dir holding config.yaml and .env.hub-bootstrap (default: $HERMES_HOME or /opt/data)",
    )
    args = parser.parse_args(argv)
    data_dir = Path(args.data_dir)
    if not data_dir.is_dir():
        log(f"WARN: {data_dir} does not exist; skipping")
        return 0
    try:
        return run(data_dir)
    except Exception as exc:  # never take the container down over config sync
        log(f"ERROR: reconcile failed: {exc.__class__.__name__}: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
