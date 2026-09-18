#!/usr/bin/env python3
"""A stand-in for `hermes` in tests/hub-handout-restart.test.sh.

It resolves the model and endpoint with the precedence upstream Hermes
(nousresearch/hermes-agent v2026.9.14) applies, and records what it resolved plus
the environment it was started with. Checked against the real image's
hermes_cli/runtime_provider.py and tui_gateway/server.py:

  model     dashboard: HERMES_MODEL / HERMES_INFERENCE_MODEL env, else config
            model.default (tui_gateway _resolve_model). gateway and the classic
            terminal CLI: config model.default only.
  base_url  a providers.<model.provider> entry with a base_url wins outright
            (_resolve_named_custom_runtime — `provider: ollama` resolves through
            providers.ollama); otherwise env CUSTOM_BASE_URL, else config
            model.base_url when the provider is "custom" or an alias of it
  api_key   the named entry's api_key; on the generic path config model.api_key
            first whenever that config base_url is trusted, then the host-gated
            OPENAI_API_KEY
  window    a model.context_length below 64000 aborts startup

Usage:
  hermes <role> [args...]          record  $FAKE_HERMES_OUT/<role>.json
  fake_hermes.py --replay <record>  re-resolve with that record's (frozen) env
                                   against the CURRENT config.yaml, the way a
                                   long-lived process sees a config change
"""

import json
import os
import sys
import tempfile

import yaml

TRACKED_ENV = (
    "CUSTOM_BASE_URL",
    "CUSTOM_API_KEY",
    "HERMES_INFERENCE_MODEL",
    "HERMES_MODEL",
    "OPENAI_MODEL",
    "OPENAI_API_KEY",
    "OPENAI_BASE_URL",
)
SECRET_ENV = ("CUSTOM_API_KEY", "OPENAI_API_KEY")
CUSTOM_ALIASES = {"custom", "ollama", "vllm", "llamacpp", "lmstudio"}
MINIMUM_CONTEXT_LENGTH = 64000
OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"


def load_config(home):
    try:
        with open(os.path.join(home, "config.yaml"), encoding="utf-8") as fh:
            return yaml.safe_load(fh) or {}
    except FileNotFoundError:
        return {}


def resolve(env, cfg, role):
    model_cfg = cfg.get("model") or {}
    if not isinstance(model_cfg, dict):
        model_cfg = {"default": model_cfg}
    env_model = (env.get("HERMES_MODEL") or env.get("HERMES_INFERENCE_MODEL") or "").strip()
    if role != "dashboard":
        env_model = ""
    model = env_model or str(model_cfg.get("default") or "")
    provider = str(model_cfg.get("provider") or "").strip().lower()
    providers = cfg.get("providers") if isinstance(cfg.get("providers"), dict) else {}
    named = providers.get(provider) if provider not in ("", "auto", "custom") else None
    named_base = str((named or {}).get("base_url") or "").strip() if isinstance(named, dict) else ""
    cfg_base = str(model_cfg.get("base_url") or "").strip()
    trusted = bool(cfg_base) and provider in CUSTOM_ALIASES
    if named_base:
        base, base_from = named_base, f"providers.{provider}"
        key = str(named.get("api_key") or "")
        key_source = f"providers.{provider}:" + ("ollama" if key == "ollama" else ("<credential>" if key else "none"))
    else:
        env_base = (env.get("CUSTOM_BASE_URL") or "").strip()
        base = env_base or (cfg_base if trusted else "") or OPENROUTER_BASE_URL
        base_from = "env" if env_base else ("config" if trusted else "default")
        if trusted and str(model_cfg.get("api_key") or "").strip():
            key_source = "config:" + ("ollama" if model_cfg.get("api_key") == "ollama" else "<credential>")
        elif "openai.com" in base and env.get("OPENAI_API_KEY"):
            key_source = "env:OPENAI_API_KEY"
        else:
            key_source = "placeholder"
    ctx = model_cfg.get("context_length")
    return {
        "model": model,
        "model_from": "env" if env_model else "config",
        "base_url": base.rstrip("/"),
        "base_url_from": base_from,
        "api_key_source": key_source,
        "context_length": ctx,
        "starts": not (isinstance(ctx, int) and ctx < MINIMUM_CONTEXT_LENGTH),
    }


def tracked(env):
    out = {}
    for key in TRACKED_ENV:
        if key in env:
            out[key] = "<set>" if key in SECRET_ENV else env[key]
    return out


def main(argv):
    if argv[:1] == ["--replay"]:
        with open(argv[1], encoding="utf-8") as fh:
            record = json.load(fh)
        # Secrets were never recorded; a placeholder keeps the host gate honest.
        env = {k: ("x" if v == "<set>" else v) for k, v in record["env"].items()}
        print(json.dumps(resolve(env, load_config(record["home"]), record["role"]), sort_keys=True))
        return 0

    role = argv[0] if argv else "cli"
    home = os.environ.get("HERMES_HOME", "/opt/data")
    record = {
        "role": role,
        "argv": argv,
        "home": home,
        "env": tracked(os.environ),
        "resolved": resolve(os.environ, load_config(home), role),
    }
    out_dir = os.environ["FAKE_HERMES_OUT"]
    fd, tmp = tempfile.mkstemp(dir=out_dir)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(record, fh, sort_keys=True)
    os.replace(tmp, os.path.join(out_dir, f"{role}.json"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
