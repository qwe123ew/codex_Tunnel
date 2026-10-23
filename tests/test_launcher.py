"""Exercise the real PowerShell 5.1 wizard and bounded launcher failure paths.

No SSH connection, authentication, proxy installation or global settings writes.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
POWERSHELL = shutil.which("powershell.exe")


@unittest.skipUnless(POWERSHELL, "Windows PowerShell 5.1 required")
class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="portable tunnel launcher ")
        self.addCleanup(self.temp.cleanup)
        self.settings = Path(self.temp.name) / "custom profile.json"
        self.protected = [Path.home() / ".codex" / "config.toml",
                          Path.home() / ".ssh" / "config"]
        self.before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in self.protected if p.is_file()}

    def tearDown(self):
        for path, expected in self.before.items():
            self.assertEqual(hashlib.sha256(Path(path).read_bytes()).hexdigest(), expected,
                             "Protected configuration changed during launcher test")

    def launch(self, *args, answers=""):
        return subprocess.run(
            [POWERSHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-File", str(ROOT / "Start-Tunnel.ps1"), "-ConfigPath", str(self.settings), *args],
            input=answers, capture_output=True, text=True, encoding="utf-8", timeout=20,
        )

    def test_first_run_wizard_direct_server_saves_only_package_profile(self):
        result = self.launch("-Configure", "-ManualSetup", answers="gpu.example.org\nalice\n2222\n\n0\n12082\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        value = json.loads(self.settings.read_text())
        self.assertEqual(value["server"], dict(host="gpu.example.org", user="alice", port=2222, identityFile=""))
        self.assertEqual(value["jumpHosts"], [])
        self.assertEqual(value["remotePort"], 12082)
        self.assertNotIn("password", self.settings.read_text().lower())

    def test_wizard_uses_distinct_ordered_jump_users_and_ports(self):
        result = self.launch("-Configure", "-ManualSetup", answers=(
            "10.10.0.9\nresearcher\n22\n\n2\n"
            "gate.example.org\nentryuser\n2200\n\n"
            "10.10.0.2\nseconduser\n2222\n\n11082\n"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        value = json.loads(self.settings.read_text())
        self.assertEqual([j["user"] for j in value["jumpHosts"]], ["entryuser", "seconduser"])
        self.assertEqual([j["port"] for j in value["jumpHosts"]], [2200, 2222])

    def test_no_prompt_refuses_missing_configuration_without_starting_ssh(self):
        result = self.launch("-NoPrompt")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Run Configure.cmd first", result.stdout)
        self.assertFalse(self.settings.exists())

    def test_diagnostics_require_no_server_and_reject_a_closed_local_port(self):
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
            # Bound but not listening, so HTTP connect fails promptly without
            # risking a request to any unrelated local service.
            result = self.launch("-CheckOnly", "-NoPrompt", "-ProxyPort", str(port))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No SSH tunnel was started", result.stdout)
        self.assertFalse(self.settings.exists())

    def test_password_field_is_rejected_before_network_or_save(self):
        profile = json.loads((ROOT / "settings.example.json").read_text())
        profile["server"]["password"] = "fixture-not-a-secret"
        self.settings.write_text(json.dumps(profile))
        before = self.settings.read_bytes()
        result = self.launch("-NoPrompt")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Do not store passwords", result.stdout)
        self.assertNotIn("fixture-not-a-secret", result.stdout + result.stderr)
        self.assertEqual(self.settings.read_bytes(), before)

    def test_package_runs_from_a_unicode_directory_with_spaces(self):
        copy_dir = Path(self.temp.name) / "隧道工具 中文目录"
        copy_dir.mkdir()
        for name in ("Start-Tunnel.ps1", "TunnelTools.ps1", "ProxyTools.ps1", "SshImport.ps1", "remote-monitor.sh"):
            shutil.copy2(ROOT / name, copy_dir / name)
        result = subprocess.run(
            [POWERSHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-File", str(copy_dir / "Start-Tunnel.ps1"), "-Configure", "-ManualSetup"],
            input="gpu.example.org\nalice\n22\n\n0\n11082\n",
            capture_output=True, text=True, encoding="utf-8", timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((copy_dir / "settings.json").read_text())["server"]["user"], "alice")

    def write_ssh_fixture(self, content):
        path = Path(self.temp.name) / "source ssh config"
        path.write_text(content, encoding="utf-8")
        return path

    def test_select_existing_alias_imports_effective_fields_and_jumps(self):
        config = self.write_ssh_fixture(
            "Host gpu\n HostName 10.12.0.8\n User scientist\n Port 2222\n"
            " ProxyJump entry,reviewer@inner:2202\n LocalForward 8898 localhost:8898\n"
            "Host entry\n HostName gate.example.org\n User entryuser\n Port 2201\n"
            "Host inner\n HostName 10.12.0.2\n User ignored\n Port 22\n")
        original = config.read_bytes()
        result = self.launch("-Configure", "-SshConfigPath", str(config), answers="1\n12082\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        value = json.loads(self.settings.read_text())
        self.assertEqual(value["server"]["host"], "10.12.0.8")
        self.assertEqual(value["server"]["user"], "scientist")
        self.assertEqual(value["server"]["port"], 2222)
        self.assertEqual([j["user"] for j in value["jumpHosts"]], ["entryuser", "reviewer"])
        self.assertEqual([j["port"] for j in value["jumpHosts"]], [2201, 2202])
        self.assertEqual(value["remotePort"], 12082)
        self.assertNotIn("8898", self.settings.read_text())
        self.assertEqual(config.read_bytes(), original)

    def test_unsupported_import_returns_to_menu_then_manual_fallback(self):
        config = self.write_ssh_fixture(
            "Host unsupported\n HostName gpu.example.org\n User alice\n"
            " ProxyCommand cmd /c echo DO_NOT_DISPLAY_COMMAND\n")
        result = self.launch("-Configure", "-SshConfigPath", str(config), answers=(
            "1\nM\ngpu.example.org\nalice\n22\n\n0\n11082\n"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ProxyCommand", result.stdout)
        self.assertNotIn("DO_NOT_DISPLAY_COMMAND", result.stdout + result.stderr)
        self.assertEqual(json.loads(self.settings.read_text())["server"]["host"], "gpu.example.org")

    def test_readonly_help_and_list_never_create_profile(self):
        config = self.write_ssh_fixture("Host first second\n HostName gpu.example.org\n User alice\n")
        result = self.launch("-ListSshHosts", "-SshConfigPath", str(config))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("first", result.stdout)
        self.assertIn("second", result.stdout)
        self.assertFalse(self.settings.exists())
        result = self.launch("-ShowSshHelp")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ssh -G YOUR_ALIAS", result.stdout)
        self.assertIn("remote.SSH.configFile", result.stdout)
        self.assertFalse(self.settings.exists())

    def test_missing_config_can_choose_another_path(self):
        config = self.write_ssh_fixture("Host gpu\n HostName gpu.example.org\n User alice\n Port 2244\n")
        missing = Path(self.temp.name) / "missing"
        result = self.launch("-Configure", "-SshConfigPath", str(missing),
                             answers="C\n{}\n1\n\n".format(config))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.settings.read_text())["server"]["port"], 2244)

    def test_manual_alias_supports_wildcard_host_rules(self):
        config = self.write_ssh_fixture("Host gpu-*\n User scientist\n Port 2244\n")
        result = self.launch("-Configure", "-SshConfigPath", str(config),
                             answers="A\ngpu-lab\n\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.settings.read_text())["server"]["host"], "gpu-lab")

    def test_cancel_preserves_existing_profile(self):
        config = self.write_ssh_fixture("Host gpu\n HostName gpu.example.org\n User alice\n")
        original = (ROOT / "settings.example.json").read_bytes()
        self.settings.write_bytes(original)
        result = self.launch("-Configure", "-SshConfigPath", str(config), answers="Q\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.settings.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
