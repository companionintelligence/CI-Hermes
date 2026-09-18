#!/usr/bin/env python3
"""Refuse an image whose upstream no longer has what enable_ollama_native.py hooks.

The shim (enable_ollama_native.py) patches Hermes by *name*: it wraps
``create_openai_client``, the two auxiliary resolvers and ``get_provider_profile``,
and imports a handful of upstream helpers to build the probe. Every one of those
is a private upstream function, and every wrap is deliberately best-effort — a
missing target is logged and the agent carries on with the stock ``/v1`` client,
which means the model loads at Ollama's 4096-token default and nothing says why.
That is the failure mode this script exists to catch at build time, where a base
image bump is being reviewed, rather than on an appliance weeks later.

It is a STATIC check — the upstream files are parsed with ``ast``, nothing is
imported — so it has no side effects, needs no HERMES_HOME, and cannot itself be
the thing that breaks the build. It verifies, for each target:

  * the module file exists in the tree;
  * the name is bound at module level — by ``def``, by an import (``hermes_cli.config``
    re-exports ``get_compatible_custom_providers`` from ``config_providers``), or
    by assignment;
  * for a ``def``, that the parameters the shim relies on positionally are still
    there, by name.

Return arity and behaviour cannot be checked statically; the shim guards those at
runtime and tests/ollama-native.smoke.sh covers them against a live image.

Usage:
    check_ollama_native_contract.py --root /opt/hermes        # exit 1 on any drift
    check_ollama_native_contract.py --root <checkout> --json   # machine-readable
"""

from __future__ import annotations

import argparse
import ast
import json
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# module path (relative to --root) -> {name: required parameter names, in order}.
# A ``None`` parameter tuple means "must be bound, but it is not a def we call with
# positional args" (re-exports, or methods found anywhere in the file).
CONTRACT: Dict[str, Dict[str, Optional[Tuple[str, ...]]]] = {
    # Hook 1 — the chat-client chokepoint. Called as (agent, client_kwargs, ...).
    "agent/agent_runtime_helpers.py": {
        "create_openai_client": ("agent", "client_kwargs"),
    },
    # Hook 2 — auxiliary side-task routers, wrapped and post-swapped.
    "agent/auxiliary_client.py": {
        "resolve_provider_client": (),
        "resolve_vision_provider_client": (),
    },
    # Hook 3 — "custom:<name>" → the "custom" profile so num_ctx is injected.
    "providers/__init__.py": {
        "get_provider_profile": ("name",),
    },
    # Helpers the shim imports to give the probe the real client's TLS trust and
    # auth material.
    "agent/ssl_verify.py": {
        "resolve_httpx_verify": ("ca_bundle", "ssl_verify", "base_url"),
    },
    "hermes_cli/providers.py": {
        "custom_provider_slug": ("display_name",),
    },
    "hermes_cli/config.py": {
        "load_config_readonly": (),
        "get_compatible_custom_providers": None,  # re-exported from config_providers
    },
}

# Names the shim reads off the agent instance (``getattr``) and calls with a
# ``verify=`` kwarg when the signature has one. They are methods on the agent
# class, and upstream moves them between mixin modules (run_agent.py in v0.19,
# agent/client_lifecycle.py in v0.21), so they are searched for across the agent
# package rather than pinned to one file.
METHOD_CONTRACT: Dict[str, Tuple[str, ...]] = {
    "_build_keepalive_http_client": ("base_url",),
}
METHOD_SEARCH_GLOBS = ("run_agent.py", "agent/*.py", "agent/**/*.py")


def _module_level_bindings(tree: ast.Module) -> Dict[str, ast.AST]:
    """Every name bound at module level, mapped to the node that binds it."""
    bound: Dict[str, ast.AST] = {}
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            bound[node.name] = node
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for alias in node.names:
                bound[alias.asname or alias.name.split(".")[0]] = node
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for target in targets:
                for leaf in ast.walk(target):
                    if isinstance(leaf, ast.Name):
                        bound[leaf.id] = node
        elif isinstance(node, ast.Try):
            # ``try: from x import y`` — common for optional re-exports.
            for sub in node.body + [h for handler in node.handlers for h in handler.body]:
                if isinstance(sub, (ast.Import, ast.ImportFrom)):
                    for alias in sub.names:
                        bound[alias.asname or alias.name.split(".")[0]] = sub
    return bound


def _param_names(fn: ast.AST) -> List[str]:
    args = fn.args  # type: ignore[attr-defined]
    return [a.arg for a in args.posonlyargs + args.args + args.kwonlyargs]


def _find_function_anywhere(tree: ast.Module, name: str) -> Optional[ast.AST]:
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return node
    return None


def check(root: Path) -> List[str]:
    """Return a list of human-readable problems; empty means the contract holds."""
    problems: List[str] = []

    def _parse(rel: str) -> Optional[ast.Module]:
        path = root / rel
        if not path.is_file():
            problems.append(f"{rel}: file missing")
            return None
        try:
            return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        except SyntaxError as exc:  # a file we cannot parse is a file we cannot vouch for
            problems.append(f"{rel}: cannot parse ({exc})")
            return None

    for rel, names in CONTRACT.items():
        tree = _parse(rel)
        if tree is None:
            continue
        bound = _module_level_bindings(tree)
        for name, params in names.items():
            node = bound.get(name)
            if node is None:
                problems.append(f"{rel}: `{name}` is no longer bound at module level")
                continue
            if params is None:
                continue
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                # Bound by import/assignment: we cannot see its signature here. That is
                # acceptable for a re-export; say so only if positional params were required.
                if params:
                    problems.append(f"{rel}: `{name}` is bound by {type(node).__name__}, not def; "
                                    f"cannot verify parameters {params}")
                continue
            have = _param_names(node)
            missing = [p for p in params if p not in have]
            if missing:
                problems.append(f"{rel}: `{name}` lost parameter(s) {missing}; signature is ({', '.join(have)})")

    if METHOD_CONTRACT:
        found: Dict[str, Tuple[str, ast.AST]] = {}
        seen: set = set()
        for pattern in METHOD_SEARCH_GLOBS:
            for path in sorted(root.glob(pattern)):
                if path in seen or not path.is_file():
                    continue
                seen.add(path)
                try:
                    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
                except (SyntaxError, UnicodeDecodeError):
                    continue  # an unparseable sibling is not this contract's concern
                for name in METHOD_CONTRACT:
                    if name in found:
                        continue
                    node = _find_function_anywhere(tree, name)
                    if node is not None:
                        found[name] = (str(path.relative_to(root)), node)
        for name, params in METHOD_CONTRACT.items():
            if name not in found:
                problems.append(f"method `{name}` not found under {', '.join(METHOD_SEARCH_GLOBS)}")
                continue
            rel, node = found[name]
            have = _param_names(node)
            missing = [p for p in params if p not in have]
            if missing:
                problems.append(f"{rel}: `{name}` lost parameter(s) {missing}; signature is ({', '.join(have)})")

    return problems


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", required=True, help="Hermes source tree (e.g. /opt/hermes)")
    parser.add_argument("--json", action="store_true", help="print {ok, problems} as JSON")
    args = parser.parse_args(argv)

    root = Path(args.root)
    problems = check(root)
    if args.json:
        print(json.dumps({"ok": not problems, "root": str(root), "problems": problems}))
    elif problems:
        print("CI ollama-native contract: upstream drift — the shim would silently fall back to /v1:", file=sys.stderr)
        for line in problems:
            print(f"  - {line}", file=sys.stderr)
    else:
        checked = sum(len(v) for v in CONTRACT.values()) + len(METHOD_CONTRACT)
        print(f"CI ollama-native contract: {checked} hook targets present in {root}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
