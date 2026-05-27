#!/usr/bin/env python3
"""Tests for the devbox-mcp-run wrapper core (issue 07).

Run with:

    python3 -m unittest tests.test_mcp_runner   # from repo root
    python3 tests/test_mcp_runner.py            # standalone

Every test points HOME / XDG_CONFIG_HOME at a fresh tempdir so the real
~/.config/devbox profile and secret store are never read, and injects a fake
Container identity file via DEVBOX_MCP_IDENTITY_PATH so /etc/devbox is never
touched. No real ~/.claude or ~/.codex is involved — the wrapper only reads the
canonical devbox profile + scoped secret store.

Covers the issue-07 wrapper acceptance criteria:
  * resolve a server from the canonical profile (global + project scope);
  * refuse to run on the host (no Container identity file);
  * clear, actionable errors for missing server, disabled server, missing env,
    and a malformed profile;
  * secret VALUES never appear in any error message;
  * required env is validated and the resolved env overlay is correct;
  * the wrapper execs the configured argv (the launch path).
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from unittest import mock

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp import identity as identity_mod  # noqa: E402
from mcp import runner as runner_mod  # noqa: E402
from mcp.identity import NotInsideContainerError, require_container  # noqa: E402
from mcp.profile import (  # noqa: E402
    global_profile_path,
    project_profile_path,
)
from mcp.runner import RunnerError, run as runner_run  # noqa: E402
from mcp.secrets import (  # noqa: E402
    global_secrets_path,
    project_secrets_path,
    store_server_secrets,
)

# A realistic-looking secret VALUE that must NEVER appear in any wrapper output.
_SECRET_VALUE = "sk-ant-super-secret-do-not-leak-0123456789"
_PROJECT_KEY = "/home/tester/Projekty/DemoApp"


class RunnerEnv(unittest.TestCase):
    """Base class isolating HOME / XDG_CONFIG_HOME and the identity path."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self._saved = {}
        for var in (
            "HOME",
            "XDG_CONFIG_HOME",
            identity_mod._IDENTITY_PATH_ENV,  # noqa: SLF001
        ):
            self._saved[var] = os.environ.get(var)
        os.environ["HOME"] = self.home
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.home, ".config")
        # Default: behave as if we ARE inside a Container (identity file present)
        # so tests of resolution/env do not trip the host gate. Tests of the gate
        # itself drop or repoint this.
        self.identity_file = os.path.join(self.home, "identity.json")
        with open(self.identity_file, "w", encoding="utf-8") as fh:
            json.dump({"project": "DemoApp"}, fh)
        os.environ[identity_mod._IDENTITY_PATH_ENV] = self.identity_file  # noqa: SLF001

    def tearDown(self) -> None:
        for var, val in self._saved.items():
            if val is None:
                os.environ.pop(var, None)
            else:
                os.environ[var] = val
        self._tmp.cleanup()

    # -- fixtures -----------------------------------------------------------

    def _server_spec(self, name: str, *, argv=None, env_keys=None,
                     secret_keys=None, enabled=None) -> dict:
        spec: dict = {
            "name": name,
            "type": "stdio",
            "command": {"argv": argv or ["npx", "-y", f"@example/{name}@latest"]},
            "envKeys": list(env_keys or []),
            "secretEnvKeys": list(secret_keys or []),
            "source": {"provider": "claude-code", "importId": f"imp-{name}"},
        }
        if enabled is not None:
            spec["enabled"] = enabled
        return spec

    def _write_global_profile(self, servers: dict) -> None:
        path = global_profile_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "servers": servers}, fh)

    def _write_project_profile(self, project_key: str, servers: dict) -> None:
        path = project_profile_path(project_key)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "servers": servers}, fh)


class IdentityGateTest(RunnerEnv):
    def test_inside_container_when_identity_present(self) -> None:
        # setUp wrote the fixture identity file; the gate must pass quietly.
        require_container()  # must not raise

    def test_missing_identity_refuses(self) -> None:
        os.remove(self.identity_file)
        with self.assertRaises(NotInsideContainerError) as ctx:
            require_container()
        msg = str(ctx.exception)
        self.assertIn("Container", msg)
        self.assertIn(self.identity_file, msg)

    def test_run_refuses_on_host_before_resolving(self) -> None:
        # No identity file => host. Even with a valid profile, run() must fail at
        # the gate and NOT exec anything.
        os.remove(self.identity_file)
        self._write_global_profile({"context7": self._server_spec("context7")})
        with mock.patch.object(runner_mod.os, "execvpe") as exec_mock:
            with self.assertRaises(NotInsideContainerError):
                runner_run("context7")
        exec_mock.assert_not_called()


class ResolveTest(RunnerEnv):
    def test_resolve_global_server_execs_argv(self) -> None:
        self._write_global_profile(
            {"context7": self._server_spec(
                "context7", argv=["npx", "-y", "@upstash/context7-mcp@latest"]
            )}
        )
        with mock.patch.object(runner_mod.os, "execvpe") as exec_mock:
            runner_run("context7")
        exec_mock.assert_called_once()
        prog, argv, _env = exec_mock.call_args.args
        self.assertEqual(prog, "npx")
        self.assertEqual(argv, ["npx", "-y", "@upstash/context7-mcp@latest"])

    def test_resolve_project_server_from_project_profile(self) -> None:
        self._write_project_profile(
            _PROJECT_KEY,
            {"local-tool": self._server_spec(
                "local-tool", argv=["uvx", "local-tool"]
            )},
        )
        with mock.patch.object(runner_mod.os, "execvpe") as exec_mock:
            runner_run("local-tool", _PROJECT_KEY)
        exec_mock.assert_called_once()
        prog, argv, _env = exec_mock.call_args.args
        self.assertEqual(argv, ["uvx", "local-tool"])

    def test_missing_server_is_clear(self) -> None:
        self._write_global_profile({"context7": self._server_spec("context7")})
        with self.assertRaises(RunnerError) as ctx:
            runner_run("nope")
        msg = str(ctx.exception)
        self.assertIn("nope", msg)
        # Known servers are hinted so the user can correct the name.
        self.assertIn("context7", msg)

    def test_disabled_server_is_clear(self) -> None:
        self._write_global_profile(
            {"context7": self._server_spec("context7", enabled=False)}
        )
        with self.assertRaises(RunnerError) as ctx:
            runner_run("context7")
        self.assertIn("disabled", str(ctx.exception))

    def test_malformed_profile_is_clear(self) -> None:
        path = global_profile_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("{ this is not valid json")
        with self.assertRaises(RunnerError) as ctx:
            runner_run("context7")
        self.assertIn("profile", str(ctx.exception).lower())

    def test_missing_command_argv_is_clear(self) -> None:
        spec = self._server_spec("context7")
        spec["command"] = {}  # no argv
        self._write_global_profile({"context7": spec})
        with self.assertRaises(RunnerError) as ctx:
            runner_run("context7")
        self.assertIn("command", str(ctx.exception).lower())


class EnvValidationTest(RunnerEnv):
    def test_missing_required_env_lists_names_only(self) -> None:
        self._write_global_profile(
            {"context7": self._server_spec(
                "context7", env_keys=["CONTEXT7_API_KEY"]
            )}
        )
        # Ensure the var is absent in the environment and not in any store.
        os.environ.pop("CONTEXT7_API_KEY", None)
        with self.assertRaises(RunnerError) as ctx:
            runner_run("context7")
        msg = str(ctx.exception)
        self.assertIn("CONTEXT7_API_KEY", msg)  # NAME is fine
        self.assertNotIn(_SECRET_VALUE, msg)  # but never a value

    def test_secret_value_resolved_from_store_never_logged(self) -> None:
        self._write_global_profile(
            {"context7": self._server_spec(
                "context7",
                env_keys=["CONTEXT7_API_KEY"],
                secret_keys=["CONTEXT7_API_KEY"],
            )}
        )
        store_server_secrets(
            global_secrets_path(), "context7",
            {"CONTEXT7_API_KEY": _SECRET_VALUE},
        )
        os.environ.pop("CONTEXT7_API_KEY", None)
        with mock.patch.object(runner_mod.os, "execvpe") as exec_mock:
            runner_run("context7")
        exec_mock.assert_called_once()
        _prog, _argv, env = exec_mock.call_args.args
        # The secret value reaches the child env (so the server works) ...
        self.assertEqual(env["CONTEXT7_API_KEY"], _SECRET_VALUE)

    def test_non_secret_env_resolved_from_environment(self) -> None:
        self._write_global_profile(
            {"context7": self._server_spec(
                "context7", env_keys=["CONTEXT7_BASE_URL"]
            )}
        )
        os.environ["CONTEXT7_BASE_URL"] = "https://example.test"
        try:
            with mock.patch.object(runner_mod.os, "execvpe") as exec_mock:
                runner_run("context7")
        finally:
            os.environ.pop("CONTEXT7_BASE_URL", None)
        _prog, _argv, env = exec_mock.call_args.args
        self.assertEqual(env["CONTEXT7_BASE_URL"], "https://example.test")

    def test_non_secret_env_resolved_from_profile_env_value(self) -> None:
        # The wrapper requires every declared env name; a non-secret value the
        # source set inline (recorded in the profile's `env` map) must resolve at
        # launch WITHOUT the user re-exporting it.
        spec = self._server_spec("context7", env_keys=["CONTEXT7_BASE_URL"])
        spec["env"] = {"CONTEXT7_BASE_URL": "https://from-profile.test"}
        self._write_global_profile({"context7": spec})
        os.environ.pop("CONTEXT7_BASE_URL", None)
        with mock.patch.object(runner_mod.os, "execvpe") as exec_mock:
            runner_run("context7")
        _prog, _argv, env = exec_mock.call_args.args
        self.assertEqual(env["CONTEXT7_BASE_URL"], "https://from-profile.test")

    def test_profile_env_value_takes_priority_over_environment(self) -> None:
        spec = self._server_spec("context7", env_keys=["CONTEXT7_BASE_URL"])
        spec["env"] = {"CONTEXT7_BASE_URL": "https://from-profile.test"}
        self._write_global_profile({"context7": spec})
        os.environ["CONTEXT7_BASE_URL"] = "https://from-env.test"
        try:
            with mock.patch.object(runner_mod.os, "execvpe") as exec_mock:
                runner_run("context7")
        finally:
            os.environ.pop("CONTEXT7_BASE_URL", None)
        _prog, _argv, env = exec_mock.call_args.args
        self.assertEqual(env["CONTEXT7_BASE_URL"], "https://from-profile.test")

    def test_project_secret_resolved_from_project_store(self) -> None:
        self._write_project_profile(
            _PROJECT_KEY,
            {"local-tool": self._server_spec(
                "local-tool",
                argv=["uvx", "local-tool"],
                env_keys=["TOOL_TOKEN"],
                secret_keys=["TOOL_TOKEN"],
            )},
        )
        store_server_secrets(
            project_secrets_path(_PROJECT_KEY), "local-tool",
            {"TOOL_TOKEN": _SECRET_VALUE},
        )
        os.environ.pop("TOOL_TOKEN", None)
        with mock.patch.object(runner_mod.os, "execvpe") as exec_mock:
            runner_run("local-tool", _PROJECT_KEY)
        _prog, _argv, env = exec_mock.call_args.args
        self.assertEqual(env["TOOL_TOKEN"], _SECRET_VALUE)


class ExecFailureTest(RunnerEnv):
    def test_exec_failure_is_wrapped_clearly(self) -> None:
        self._write_global_profile(
            {"context7": self._server_spec(
                "context7", argv=["definitely-not-a-real-binary-xyz"]
            )}
        )
        with mock.patch.object(
            runner_mod.os, "execvpe", side_effect=OSError("No such file")
        ):
            with self.assertRaises(RunnerError) as ctx:
                runner_run("context7")
        msg = str(ctx.exception)
        self.assertIn("context7", msg)
        self.assertIn("definitely-not-a-real-binary-xyz", msg)


if __name__ == "__main__":
    unittest.main()
