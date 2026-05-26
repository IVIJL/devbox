"""Import providers for `devbox mcp import` (ADR 0013).

A provider reads one agent's existing MCP configuration and normalizes its
records into the provider-neutral candidate shape from `mcp.candidate`. The
first provider is Claude Code (`mcp.providers.claude`); Codex and other agent
sources land in later issues.

Providers are read-only: they parse existing config and never write to agent
config or devbox state. They report environment-variable *names* only — secret
*values* never enter a Candidate (ADR 0013, decisions 25-26).
"""

from .claude import ClaudeProvider

__all__ = ["ClaudeProvider"]
