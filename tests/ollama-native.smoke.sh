#!/usr/bin/env bash
# Smoke test for the native Ollama (/api/chat) adapter (patches/).
#
# Runs the adapter inside a running CI-Hermes container against a reachable Ollama
# and asserts the decisive property: a chat request with num_ctx=64000 makes Ollama
# actually load the model at 64000 (which the OpenAI-compat /v1 endpoint cannot do).
# Also exercises unit translation + the flag-gated, /api/version-probed detection.
#
# Usage:
#   CONTAINER=<hermes-container> OLLAMA_URL=http://172.17.0.1:11434 MODEL=gemma4:e2b \
#     bash tests/ollama-native.smoke.sh
#
# Defaults target the local marketplace container. Non-destructive: copies the
# adapter + test to the container's /tmp (never into site-packages) and cleans up.
set -euo pipefail

CONTAINER="${CONTAINER:-ci-hermes_ci-marketplace-ci-hermes-1}"
OLLAMA_URL="${OLLAMA_URL:-http://172.17.0.1:11434}"
MODEL="${MODEL:-gemma4:e2b}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ADAPTER="$HERE/patches/ollama_native_adapter.py"

[ -f "$ADAPTER" ] || { echo "adapter not found: $ADAPTER" >&2; exit 1; }
docker exec "$CONTAINER" true 2>/dev/null || { echo "container not running: $CONTAINER" >&2; exit 1; }

TEST_PY="$(mktemp /tmp/ollama-native-smoke.XXXXXX.py)"
trap 'rm -f "$TEST_PY"' EXIT
cat > "$TEST_PY" <<'PY'
import os, sys, time, httpx
sys.path.insert(0, "/tmp")
import ollama_native_adapter as A
OLLAMA, MODEL = os.environ["OLLAMA_URL"], os.environ["MODEL"]

# unit: request build + response/stream translation
req = A.build_ollama_request(model=MODEL, messages=[{"role": "user", "content": "x"}],
                             options={"num_ctx": 64000}, max_tokens=8)
assert req["options"]["num_ctx"] == 64000
r = A.translate_ollama_response({"message": {"role": "assistant", "content": "hi"},
                                 "done": True, "prompt_eval_count": 2, "eval_count": 1}, MODEL)
assert r.choices[0].message.content == "hi" and r.usage.total_tokens == 3
ti = {"n": 0}; ch = []
for ln in [{"message": {"content": "a"}}, {"done": True, "done_reason": "stop"}]:
    ch += A.translate_stream_line(ln, MODEL, ti)
assert "".join(c.choices[0].delta.content or "" for c in ch) == "a"
print("unit translation: OK")

# regression: default_headers copied from an OpenAI SDK client (aux Hook-2 path) can
# carry the SDK's Omit()/NotGiven sentinels for unset headers (OpenAI-Organization/
# -Project). httpx rejects non-str header values, which silently broke every aux
# side-task (title/compression/vision). _headers() must drop them.
import openai as _openai
_sentinels = [s for s in (getattr(_openai, "Omit", None), getattr(_openai, "NotGiven", None)) if s is not None]
assert _sentinels, "expected openai.Omit/NotGiven to exist"
_hc = A.OllamaNativeClient(base_url=OLLAMA + "/v1",
                           default_headers={"OpenAI-Organization": _sentinels[0](), "X-CI-Real": "yes"})
_h = _hc._headers()
assert "OpenAI-Organization" not in _h, f"Omit sentinel leaked into headers: {_h}"
assert _h.get("X-CI-Real") == "yes", _h
assert all(isinstance(v, (str, bytes)) for v in _h.values()), _h
print("unit Omit/NotGiven header filtering: OK")

# detection: flag gate + /api/version probe (works with or without /v1)
os.environ.pop("CI_HERMES_OLLAMA_NATIVE", None)
assert A.is_native_ollama_base_url(OLLAMA) is False
os.environ["CI_HERMES_OLLAMA_NATIVE"] = "1"; A._OLLAMA_PROBE_CACHE.clear()
assert A.is_native_ollama_base_url(OLLAMA + "/v1") is True
print("detection (flag + /api/version probe, /v1-agnostic): OK")

# live: prove Ollama loads at num_ctx=64000 via native /api/chat
httpx.post(f"{OLLAMA}/api/chat", json={"model": MODEL, "keep_alive": 0, "messages": []}, timeout=30); time.sleep(1)
client = A.OllamaNativeClient(base_url=OLLAMA + "/v1")
client.chat.completions.create(model=MODEL, messages=[{"role": "user", "content": "hi"}],
                               extra_body={"options": {"num_ctx": 64000}}, max_tokens=4)
ctx = [m.get("context_length") for m in httpx.get(f"{OLLAMA}/api/ps", timeout=30).json().get("models", [])
       if m.get("name") == MODEL]
assert ctx and ctx[0] == 64000, f"expected 64000, got {ctx}"
httpx.post(f"{OLLAMA}/api/chat", json={"model": MODEL, "keep_alive": 0, "messages": []}, timeout=30)
print(f"live: Ollama loaded {MODEL} at context={ctx[0]} via /api/chat")
print("SMOKE TEST PASSED")
PY

cat >> "$TEST_PY" <<'PY'

# Hook 2 (phase 2): aux side-task routers route native Ollama through /api/chat
import enable_ollama_native            # installs the post-import patcher (flag set above)
import agent.auxiliary_client as aux   # -> patched on import
import ollama_native_adapter as _A
assert getattr(aux.resolve_provider_client, "_ci_ollama_wrapped", False)
assert getattr(aux.resolve_vision_provider_client, "_ci_ollama_wrapped", False)
sc, _ = aux.resolve_provider_client("custom", model=MODEL, explicit_base_url=OLLAMA + "/v1", explicit_api_key="ollama")
assert isinstance(sc, _A.OllamaNativeClient)
acl, _ = aux.resolve_provider_client("custom", model=MODEL, async_mode=True, explicit_base_url=OLLAMA + "/v1", explicit_api_key="ollama")
assert isinstance(acl, _A.AsyncOllamaNativeClient)
_, vcl, _ = aux.resolve_vision_provider_client(model=MODEL, base_url=OLLAMA + "/v1", api_key="ollama")
assert isinstance(vcl, _A.OllamaNativeClient)
print("Hook 2 aux routers (text sync/async + vision): native — OK")

# end-to-end: an ACTUAL aux call must succeed (not just resolve to a native client).
# This mirrors title/compression/vision, which go through call_llm -> the resolved
# client -> _headers(); it is the path the Omit-sentinel header bug broke.
_r = sc.chat.completions.create(model=MODEL, messages=[{"role": "user", "content": "Reply with the word OK"}],
                                extra_body={"options": {"num_ctx": 64000}, "think": False}, max_tokens=8)
assert _r.choices[0].message is not None and (_r.choices[0].message.content or "").strip(), _r
print(f"Hook 2 aux real call via /api/chat: OK ({(_r.choices[0].message.content or '').strip()[:20]!r})")

# end-to-end: the actual title-generation helper (the symptom the user hit).
from agent.title_generator import generate_title
_t = generate_title("hey what is date today", "Today is 2026-06-28.",
                    main_runtime={"model": MODEL, "provider": "ollama",
                                  "base_url": OLLAMA + "/v1", "api_key": "ollama", "api_mode": None})
assert _t, "title generation returned None (aux path broken)"
print(f"title_generation end-to-end: OK ({_t!r})")
print("PHASE 2 SMOKE PASSED")
PY

ADAPTER_SHIM="$HERE/patches/enable_ollama_native.py"
docker cp "$ADAPTER" "$CONTAINER:/tmp/ollama_native_adapter.py" >/dev/null
docker cp "$ADAPTER_SHIM" "$CONTAINER:/tmp/enable_ollama_native.py" >/dev/null
docker cp "$TEST_PY" "$CONTAINER:/tmp/ollama_native_smoke.py" >/dev/null
docker exec -e OLLAMA_URL="$OLLAMA_URL" -e MODEL="$MODEL" -e CI_HERMES_OLLAMA_NATIVE="1" "$CONTAINER" \
  /opt/hermes/.venv/bin/python /tmp/ollama_native_smoke.py
# Clean up only the files this run created (incl. their bytecode caches) — never the
# whole /tmp/__pycache__, which may hold unrelated caches.
docker exec "$CONTAINER" sh -c 'rm -f /tmp/ollama_native_adapter.py /tmp/enable_ollama_native.py /tmp/ollama_native_smoke.py /tmp/__pycache__/ollama_native_adapter.*.pyc /tmp/__pycache__/enable_ollama_native.*.pyc /tmp/__pycache__/ollama_native_smoke.*.pyc' || true
