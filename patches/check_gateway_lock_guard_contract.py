#!/usr/bin/env python3
"""Refuse an image whose upstream no longer has what enable_gateway_lock_guard.py wraps.

The shim wraps ``gateway.status._cleanup_invalid_pid_path`` so the web container stops
deleting the gateway's ``gateway.pid`` and ``gateway.lock`` while the gateway (in its own
container) holds the lock. The wrap is best-effort by design: a renamed target is logged
and upstream's cleanup runs, and the first ``hermes cron run`` or dashboard poll in the web
container deletes the files again. ``hermes cron list`` then warns that the gateway isn't
running when it is. This script catches that at build time.

It is a STATIC check: files are parsed with ``ast`` and nothing is imported. It verifies:

  * ``gateway/status.py`` defines ``_cleanup_invalid_pid_path(pid_path, *, cleanup_stale)``,
    ``_get_gateway_lock_path``, ``is_gateway_runtime_lock_active`` and
    ``_clear_running_pid_cache`` at module level (the wrapper calls all four);
  * ``get_running_pid`` in that file still calls ``_cleanup_invalid_pid_path`` by name, so
    swapping the module attribute reaches it;
  * ``hermes_cli/cron.py``'s ``_builtin_gateway_liveness`` still asks
    ``is_gateway_runtime_lock_active``, the answer the kept lock gives ``hermes cron list``.

Usage:
    check_gateway_lock_guard_contract.py --root /opt/hermes        # exit 1 on any drift
    check_gateway_lock_guard_contract.py --root <checkout> --json   # machine-readable
"""

from __future__ import annotations

import argparse
import ast
import json
import sys
from pathlib import Path
from typing import Dict, List, Optional

STATUS_MODULE = "gateway/status.py"
TARGET = "_cleanup_invalid_pid_path"
HELPERS = ("_get_gateway_lock_path", "is_gateway_runtime_lock_active", "_clear_running_pid_cache")
CALLER = "get_running_pid"
CRON_MODULE = "hermes_cli/cron.py"
CRON_LIVENESS = "_builtin_gateway_liveness"
LOCK_PROBE = "is_gateway_runtime_lock_active"


def _module_functions(tree: ast.Module) -> Dict[str, ast.AST]:
    return {node.name: node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}


def _calls_name(fn: ast.AST, name: str) -> bool:
    for node in ast.walk(fn):
        if isinstance(node, ast.Call):
            f = node.func
            if (isinstance(f, ast.Name) and f.id == name) or (isinstance(f, ast.Attribute) and f.attr == name):
                return True
    return False


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
        except SyntaxError as exc:
            problems.append(f"{rel}: cannot parse ({exc})")
            return None

    tree = _parse(STATUS_MODULE)
    if tree is not None:
        fns = _module_functions(tree)
        target = fns.get(TARGET)
        if target is None:
            problems.append(f"{STATUS_MODULE}: `{TARGET}` is no longer a module-level function")
        else:
            args = target.args
            positional = [a.arg for a in args.posonlyargs + args.args]
            keyword_only = [a.arg for a in args.kwonlyargs]
            if positional != ["pid_path"] or keyword_only != ["cleanup_stale"]:
                problems.append(f"{STATUS_MODULE}: `{TARGET}` signature changed to ({', '.join(positional)}, *, "
                                f"{', '.join(keyword_only)}); the wrapper expects (pid_path, *, cleanup_stale)")
        for helper in HELPERS:
            if helper not in fns:
                problems.append(f"{STATUS_MODULE}: `{helper}` is no longer a module-level function")
        caller = fns.get(CALLER)
        if caller is None:
            problems.append(f"{STATUS_MODULE}: `{CALLER}` is no longer a module-level function")
        elif not _calls_name(caller, TARGET):
            problems.append(f"{STATUS_MODULE}: `{CALLER}` no longer calls `{TARGET}`")

    tree = _parse(CRON_MODULE)
    if tree is not None:
        liveness = _module_functions(tree).get(CRON_LIVENESS)
        if liveness is None:
            problems.append(f"{CRON_MODULE}: `{CRON_LIVENESS}` is no longer a module-level function")
        elif not _calls_name(liveness, LOCK_PROBE):
            problems.append(f"{CRON_MODULE}: `{CRON_LIVENESS}` no longer asks `{LOCK_PROBE}`")

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
        print("CI gateway-lock-guard contract: upstream drift, so the web container would delete the "
              "gateway's lock again:", file=sys.stderr)
        for line in problems:
            print(f"  - {line}", file=sys.stderr)
    else:
        print(f"CI gateway-lock-guard contract: cleanup, lock helpers and cron liveness present in {root}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
