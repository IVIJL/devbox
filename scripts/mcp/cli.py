"""JSON entry point for `devbox mcp` (ADR 0013, issue 01 skeleton).

The shell dispatcher `scripts/mcp-cli.sh` owns human-readable output and arg
parsing; it shells out to this module only for the machine-readable `--json`
paths so the candidate-model serialization lives in one place (the Python
core). Invoked as:

    python3 -m mcp.cli import-json
    python3 -m mcp.cli list-inherited-json

with `scripts/` on PYTHONPATH so `import mcp` resolves to this package.

This slice has no providers, so both commands emit a versioned envelope with
an empty candidate array. The envelope shape is the permanent contract; only
the array contents change once providers land (issues 02+).
"""

from __future__ import annotations

import json
import sys

from . import import_result, inherited_list_result


def _emit(payload: dict) -> int:
    json.dump(payload, sys.stdout, indent=2, sort_keys=False)
    sys.stdout.write("\n")
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        sys.stderr.write("mcp.cli: missing command\n")
        return 2
    command = argv[0]
    if command == "import-json":
        # No import providers active yet -> empty candidates array.
        return _emit(import_result([]))
    if command == "list-inherited-json":
        # No inherited candidates detected yet -> empty inherited array.
        return _emit(inherited_list_result([]))
    sys.stderr.write(f"mcp.cli: unknown command {command!r}\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
