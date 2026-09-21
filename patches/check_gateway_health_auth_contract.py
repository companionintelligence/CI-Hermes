#!/usr/bin/env python3
"""Refuse an image whose upstream no longer has what enable_gateway_health_auth.py replaces.

The shim swaps ``hermes_cli.web_server_gateway._probe_gateway_health`` for a copy that
sends the Bearer key, and that copy reads ``_GATEWAY_HEALTH_URL`` / ``_GATEWAY_HEALTH_TIMEOUT``
from ``hermes_cli.web_server`` exactly as upstream's does. The swap is best-effort by
design: a renamed target is logged and the stock, unauthenticated probe runs — the
gateway is back to logging ``API server rejected invalid API key`` on every poll and
nothing says why. This script catches that at build time, where the base image bump is
being reviewed, instead of on an appliance weeks later.

It is a STATIC check — files are parsed with ``ast``, nothing is imported — so it has
no side effects and needs no HERMES_HOME. It verifies:

  * ``hermes_cli/web_server_gateway.py`` defines ``_probe_gateway_health`` at module
    level, with no parameters (callers invoke it bare through ``web_deps.late``);
  * ``hermes_cli/web_server.py`` binds ``_GATEWAY_HEALTH_URL`` and
    ``_GATEWAY_HEALTH_TIMEOUT`` at module level;
  * ``gateway/platforms/api_server.py`` still routes ``/health/detailed``, still keys the
    server off ``API_SERVER_KEY``, and its auth check still reads a ``Bearer`` token —
    the three facts that make the header the shim sends the right one.

Usage:
    check_gateway_health_auth_contract.py --root /opt/hermes        # exit 1 on any drift
    check_gateway_health_auth_contract.py --root <checkout> --json   # machine-readable
"""

from __future__ import annotations

import argparse
import ast
import json
import sys
from pathlib import Path
from typing import Dict, List, Optional

PROBE_MODULE = "hermes_cli/web_server_gateway.py"
PROBE_NAME = "_probe_gateway_health"
SETTINGS_MODULE = "hermes_cli/web_server.py"
SETTINGS_NAMES = ("_GATEWAY_HEALTH_URL", "_GATEWAY_HEALTH_TIMEOUT")
API_SERVER_MODULE = "gateway/platforms/api_server.py"
API_SERVER_AUTH_FN = "_check_auth"
# Literal strings that must still appear in api_server.py: the route the probe leads
# with, the env var the server validates, and the header scheme it accepts.
API_SERVER_LITERALS = ("/health/detailed", "API_SERVER_KEY", "Bearer ")


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
            for sub in node.body + [h for handler in node.handlers for h in handler.body]:
                if isinstance(sub, (ast.Assign, ast.AnnAssign)):
                    targets = sub.targets if isinstance(sub, ast.Assign) else [sub.target]
                    for target in targets:
                        for leaf in ast.walk(target):
                            if isinstance(leaf, ast.Name):
                                bound[leaf.id] = sub
    return bound


def _string_literals(tree: ast.Module) -> set:
    return {node.value for node in ast.walk(tree)
            if isinstance(node, ast.Constant) and isinstance(node.value, str)}


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

    tree = _parse(PROBE_MODULE)
    if tree is not None:
        node = _module_level_bindings(tree).get(PROBE_NAME)
        if node is None:
            problems.append(f"{PROBE_MODULE}: `{PROBE_NAME}` is no longer bound at module level")
        elif not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            problems.append(f"{PROBE_MODULE}: `{PROBE_NAME}` is bound by {type(node).__name__}, not def")
        else:
            args = node.args
            params = [a.arg for a in args.posonlyargs + args.args + args.kwonlyargs]
            required = params[:len(params) - len(args.defaults)] if args.defaults else params
            if required or args.vararg:
                problems.append(f"{PROBE_MODULE}: `{PROBE_NAME}` now takes parameters ({', '.join(params)}); "
                                "the shim's replacement takes none")

    tree = _parse(SETTINGS_MODULE)
    if tree is not None:
        bound = _module_level_bindings(tree)
        for name in SETTINGS_NAMES:
            if name not in bound:
                problems.append(f"{SETTINGS_MODULE}: `{name}` is no longer bound at module level")

    tree = _parse(API_SERVER_MODULE)
    if tree is not None:
        literals = _string_literals(tree)
        for literal in API_SERVER_LITERALS:
            if literal not in literals:
                problems.append(f"{API_SERVER_MODULE}: literal {literal!r} no longer appears")
        if not any(isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == API_SERVER_AUTH_FN
                   for n in ast.walk(tree)):
            problems.append(f"{API_SERVER_MODULE}: `{API_SERVER_AUTH_FN}` not found")

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
        print("CI gateway-health-auth contract: upstream drift — the dashboard probe would run "
              "unauthenticated again:", file=sys.stderr)
        for line in problems:
            print(f"  - {line}", file=sys.stderr)
    else:
        print(f"CI gateway-health-auth contract: probe, settings and API server auth present in {root}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
