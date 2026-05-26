"""Provider-neutral MCP candidate model (ADR 0013 + local-plan-mcp.md slice 1).

This is the single place where the shape of an *import candidate* lives. Every
later import provider (Claude Code, Codex, and future Cursor/PI/`.mcp.json`
sources) normalizes its discovered records into this shape, and every command
that emits `--json` serializes from here. Keeping the shape in one module means
provider merge (issue 03) and classification (issue 04) reuse it instead of
re-deriving an ad-hoc dict.

Terminology follows CONTEXT.md § MCP: a discovered, not-yet-trusted server is
an "Inherited MCP server"; a candidate is the normalized record describing one
such server as a possible entry for an MCP profile.

Secret-safety rule (ADR 0013, decisions 25-26): this model never carries
secret *values*. `Command.env_keys` and `Command.secret_env_keys` are
environment-variable *names* only. Serialization here can therefore be emitted
to logs, tables, and JSON without redaction passes, because no value ever
enters the model.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Optional

# Schema version for the candidate / result JSON envelope. Bump when the
# serialized shape changes so later migrations (issue 02+) can branch on it.
# Matches the spirit of the profile `version` field in local-plan-mcp.md
# decision 24.
SCHEMA_VERSION = 1

# Allowed classification placements (local-plan-mcp.md core question 9).
# A candidate's placement separates *where it should run* from *how confident*
# devbox is about that. This slice does not classify anything yet, so callers
# leave placement as "unknown"; the constant set is defined now so providers
# and the classifier (issue 04) share one vocabulary.
PLACEMENTS = ("container", "host-only", "unknown", "excluded")

# Allowed classification confidences (local-plan-mcp.md core question 9).
CONFIDENCES = ("high", "medium", "low")


@dataclass
class Command:
    """How an Inherited/Devbox MCP server is launched.

    Stored as an `argv` array (never a shell string) per local-plan-mcp.md
    decision 24. Env is split into:

      * `env_keys`      — names of all environment variables the server
                          references, secret or not.
      * `secret_env_keys` — subset of `env_keys` whose *values* are sensitive
                          (API keys, tokens). Names only — values never live
                          in this model.
    """

    argv: list[str] = field(default_factory=list)
    env_keys: list[str] = field(default_factory=list)
    secret_env_keys: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "argv": list(self.argv),
            "envKeys": list(self.env_keys),
            "secretEnvKeys": list(self.secret_env_keys),
        }


@dataclass
class Classification:
    """Placement decision plus its confidence and supporting reasons.

    `placement` is one of PLACEMENTS, `confidence` is one of CONFIDENCES (or
    None when unclassified), and `reasons` is a human-readable evidence list
    (local-plan-mcp.md core question 9). This slice produces no classification,
    so the default is an unknown placement with no confidence and no reasons.
    """

    placement: str = "unknown"
    confidence: Optional[str] = None
    reasons: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        if self.placement not in PLACEMENTS:
            raise ValueError(
                f"invalid placement {self.placement!r}; "
                f"expected one of {PLACEMENTS}"
            )
        if self.confidence is not None and self.confidence not in CONFIDENCES:
            raise ValueError(
                f"invalid confidence {self.confidence!r}; "
                f"expected one of {CONFIDENCES} or None"
            )

    def to_dict(self) -> dict[str, Any]:
        return {
            "placement": self.placement,
            "confidence": self.confidence,
            "reasons": list(self.reasons),
        }


@dataclass
class Candidate:
    """One normalized Inherited MCP server candidate (ADR 0013).

    Fields are exactly those required by ADR 0013 and local-plan-mcp.md
    slice 1 ("Candidate shape should include"):

      * provider      — import provider that discovered it (e.g. "claude-code",
                        "codex").
      * source_path   — absolute path of the agent config file it came from.
      * source_scope  — "global" or "project" (where the inherited server was
                        configured).
      * source_project — project key when source_scope is "project"; None for
                        global.
      * name          — the server name as it appears in the source config.
      * type          — transport/type as reported by the source (e.g. "stdio");
                        None when the source does not specify one.
      * command       — Command (argv + env key names + secret env key names).
      * classification — Classification (placement / confidence / reasons).
    """

    provider: str
    source_path: str
    source_scope: str
    name: str
    source_project: Optional[str] = None
    type: Optional[str] = None
    command: Command = field(default_factory=Command)
    classification: Classification = field(default_factory=Classification)

    def to_dict(self) -> dict[str, Any]:
        return {
            "provider": self.provider,
            "sourcePath": self.source_path,
            "sourceScope": self.source_scope,
            "sourceProject": self.source_project,
            "name": self.name,
            "type": self.type,
            "command": self.command.to_dict(),
            "classification": self.classification.to_dict(),
        }


def import_result(candidates: Optional[list[Candidate]] = None) -> dict[str, Any]:
    """Build the `devbox mcp import --json` envelope.

    Stable contract from the very first slice: a versioned object with a
    `candidates` array. With no providers active yet the array is empty, but
    the shape is identical once providers land in later issues.
    """

    cands = candidates or []
    return {
        "version": SCHEMA_VERSION,
        "candidates": [c.to_dict() for c in cands],
    }


def inherited_list_result(
    candidates: Optional[list[Candidate]] = None,
) -> dict[str, Any]:
    """Build the `devbox mcp list --inherited --json` envelope.

    `list --inherited` reports detected Inherited MCP servers (local-plan-mcp.md
    decision 22). Same candidate shape as import; empty until providers exist.
    """

    cands = candidates or []
    return {
        "version": SCHEMA_VERSION,
        "inherited": [c.to_dict() for c in cands],
    }
