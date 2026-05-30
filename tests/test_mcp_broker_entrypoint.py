"""Structural checks for the broker's entrypoint + Dockerfile wiring.

The runtime UID-boundary properties (the broker holding only devbox-mcp's
groups, node failing `kill -0` against the broker, /proc/<pid>/environ being
unreadable cross-UID) are CONTAINER-RUNTIME-ONLY: they require a live container
and cannot be exercised from a unit test here. This module instead verifies, by
construction, that the source wiring that PRODUCES those properties is present
and correct, so the host validation has a precise contract to confirm:

  * the entrypoint starts the broker as devbox-mcp with the FULL credential
    reset (--reuid + --regid + --init-groups), BEFORE the node drop, in the
    root phase;
  * the broker is backgrounded (always-on) and runs the devbox-mcp-broker
    launcher;
  * the Dockerfile creates an unprivileged devbox-mcp account with its own HOME
    and npm/npx cache, adds node to the devbox-mcp group (socket reach only),
    and grants devbox-mcp NO sudo;
  * ADR 0003 invariants: no NOPASSWD sudoers entry is introduced for the broker.
"""

from __future__ import annotations

import os
import re
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENTRYPOINT = os.path.join(REPO_ROOT, "scripts", "devbox-entrypoint.sh")
DOCKERFILE = os.path.join(REPO_ROOT, "Dockerfile")


def _read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


class EntrypointBrokerTests(unittest.TestCase):
    def setUp(self):
        self.text = _read(ENTRYPOINT)

    def test_broker_started_before_node_drop(self):
        broker_idx = self.text.find("devbox-mcp-broker")
        node_drop_idx = self.text.find("--reuid=node")
        self.assertNotEqual(broker_idx, -1, "broker start missing")
        self.assertNotEqual(node_drop_idx, -1, "node drop missing")
        self.assertLess(
            broker_idx, node_drop_idx, "broker must start before the node drop"
        )

    def test_broker_full_credential_reset(self):
        # The broker's setpriv must reset uid AND gid AND init-groups, not just
        # uid — otherwise it retains root's groups (ADR 0014).
        m = re.search(
            r"setpriv\s+--reuid=devbox-mcp\s+--regid=devbox-mcp\s+--init-groups",
            self.text,
        )
        self.assertIsNotNone(
            m, "broker setpriv must use --reuid + --regid + --init-groups"
        )

    def test_broker_is_backgrounded(self):
        # The broker is always-on; it must be backgrounded so the script
        # proceeds to the node exec.
        self.assertRegex(
            self.text,
            r"/usr/local/bin/devbox-mcp-broker\s*&",
        )

    def test_node_drop_is_exec(self):
        # PID 1 still becomes node via exec setpriv (no residual root parent).
        self.assertIn(
            "exec setpriv --reuid=node --regid=node --init-groups", self.text
        )

    def test_socket_dir_owned_by_devbox_mcp_not_secret_dir(self):
        # The socket dir is created for devbox-mcp and is NOT a 0700 secret dir
        # (node must be able to traverse to connect via its group membership).
        self.assertRegex(
            self.text,
            r"install -d -o devbox-mcp -g devbox-mcp -m 0750 /run/devbox-mcp",
        )

    def test_broker_launched_with_clean_devbox_mcp_env(self):
        # The broker (and the servers it spawns) must run with devbox-mcp's own
        # HOME / npm cache, not root's inherited environment, so npx servers can
        # write their cache. `env -i` resets the environment before setting it.
        self.assertIn("env -i", self.text)
        self.assertRegex(self.text, r"HOME=/home/devbox-mcp")
        self.assertRegex(self.text, r"npm_config_cache=/home/devbox-mcp/\.npm")

    def test_broker_reads_profile_mount_not_own_home(self):
        # XDG_CONFIG_HOME must point at the node-readable profile mount so the
        # broker reads the same (secret-free) profile the host writes.
        self.assertRegex(self.text, r"XDG_CONFIG_HOME=/home/node/\.config")

    def test_private_staged_secret_dir_is_0700_devbox_mcp(self):
        # Secret VALUES come from a devbox-mcp-private 0700 dir node cannot
        # traverse — never from the node-owned profile mount.
        self.assertRegex(
            self.text,
            r"install -d -o devbox-mcp -g devbox-mcp -m 0700 "
            r"/run/devbox-mcp/secrets",
        )
        self.assertRegex(
            self.text, r"DEVBOX_MCP_SECRETS_DIR=/run/devbox-mcp/secrets"
        )

    def test_identity_records_full_project_key(self):
        # The identity file must carry projectKey (the full host path) so the
        # broker can bind Project scope to exactly this Container.
        self.assertIn("projectKey", self.text)
        self.assertIn("DEVBOX_PROJECT_HOST_PATH", self.text)


class DockerfileAccountTests(unittest.TestCase):
    def setUp(self):
        self.text = _read(DOCKERFILE)

    def test_devbox_mcp_account_created_unprivileged(self):
        self.assertIn("groupadd --system devbox-mcp", self.text)
        self.assertRegex(
            self.text,
            r"useradd --system --gid devbox-mcp --create-home",
        )

    def test_devbox_mcp_has_own_home_and_npm_cache(self):
        self.assertIn("/home/devbox-mcp/.npm", self.text)
        self.assertIn("--home-dir /home/devbox-mcp", self.text)

    def test_node_added_to_devbox_mcp_group_for_socket(self):
        self.assertIn("usermod -aG devbox-mcp node", self.text)

    def test_devbox_mcp_not_granted_sudo(self):
        # The only `usermod -aG sudo` in the image is for node (firewall
        # password sudo); devbox-mcp must never be added to sudo.
        self.assertNotRegex(self.text, r"usermod -aG sudo[^\n]*devbox-mcp")
        self.assertNotRegex(self.text, r"devbox-mcp[^\n]*-aG sudo")

    def test_no_nopasswd_sudoers_for_broker(self):
        # ADR 0003: no NOPASSWD sudoers entries are introduced.
        self.assertNotIn("NOPASSWD", self.text)

    def test_broker_launcher_shipped_and_executable(self):
        self.assertIn(
            "COPY scripts/mcp-broker.sh /usr/local/bin/devbox-mcp-broker", self.text
        )
        self.assertIn("/usr/local/bin/devbox-mcp-broker", self.text)

    def test_mcp_runtime_readable_by_devbox_mcp(self):
        # The shared MCP package must be readable+executable by devbox-mcp.
        self.assertRegex(
            self.text, r"chmod -R a\+rX /usr/local/share/devbox/mcp"
        )


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
