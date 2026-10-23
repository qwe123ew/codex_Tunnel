"""Offline integration tests against the real, built single-file Windows EXE.

Build dist/CodexProxyTunnel.exe first, then run this file with Python 3.8+.
Every invocation runs a copy of only the EXE in a Unicode path with spaces.
No SSH login or external network connection is needed. All generated files,
including extraction and default configuration paths, stay in a test sandbox.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILT_EXE = ROOT / "dist" / "CodexProxyTunnel.exe"


def fingerprint(path):
    """Record absence too, so creating a formerly absent file also fails."""
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def owned_powershell_handle(parent_pid):
    """Open only the real EXE's direct PowerShell child, using Windows APIs."""
    import ctypes
    from ctypes import wintypes

    class ProcessEntry(ctypes.Structure):
        _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                    ("th32ProcessID", wintypes.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
                    ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                    ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", wintypes.LONG),
                    ("dwFlags", wintypes.DWORD), ("szExeFile", wintypes.WCHAR * 260)]

    api = ctypes.WinDLL("kernel32", use_last_error=True)
    api.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    api.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    for name in ("Process32FirstW", "Process32NextW"):
        function = getattr(api, name)
        function.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry)]
        function.restype = wintypes.BOOL
    api.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    api.OpenProcess.restype = wintypes.HANDLE
    api.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    api.WaitForSingleObject.restype = wintypes.DWORD
    api.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    api.TerminateProcess.restype = wintypes.BOOL
    api.CloseHandle.argtypes = [wintypes.HANDLE]
    api.CloseHandle.restype = wintypes.BOOL

    snapshot = api.CreateToolhelp32Snapshot(0x00000002, 0)
    if snapshot == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        entry = ProcessEntry()
        entry.dwSize = ctypes.sizeof(entry)
        has_entry = api.Process32FirstW(snapshot, ctypes.byref(entry))
        while has_entry:
            if entry.th32ParentProcessID == parent_pid and entry.szExeFile.lower() == "powershell.exe":
                # SYNCHRONIZE checks the original process object even after PID
                # reuse. PROCESS_TERMINATE is only a failed-test cleanup fallback.
                handle = api.OpenProcess(0x00100001, False, entry.th32ProcessID)
                if not handle:
                    raise ctypes.WinError(ctypes.get_last_error())
                return api, handle
            has_entry = api.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        api.CloseHandle(snapshot)
    raise AssertionError("The waiting EXE has no direct PowerShell child")


@unittest.skipUnless(os.name == "nt", "The built EXE requires Windows")
class ExeIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BUILT_EXE.is_file():
            raise RuntimeError("Build dist/CodexProxyTunnel.exe before running EXE integration tests")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex exe integration ")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.program_dir = self.base / "独立程序 中文路径"
        self.cwd = self.base / "另一个 working directory"
        self.runtime_temp = self.base / "运行 temp"
        self.local_appdata = self.base / "local app data"
        for path in (self.program_dir, self.cwd, self.runtime_temp, self.local_appdata):
            path.mkdir()
        self.exe = self.program_dir / BUILT_EXE.name
        shutil.copy2(str(BUILT_EXE), str(self.exe))
        self.settings = self.base / "profile ' & 配置.json"
        self.env = dict(os.environ, TEMP=str(self.runtime_temp), TMP=str(self.runtime_temp),
                        LOCALAPPDATA=str(self.local_appdata))
        protected = [Path.home() / ".codex" / "config.toml", Path.home() / ".ssh" / "config"]
        self.protected_before = {path: fingerprint(path) for path in protected}
        self.addCleanup(self.assert_protected_configuration_unchanged)

    def assert_protected_configuration_unchanged(self):
        for path, before in self.protected_before.items():
            self.assertEqual(fingerprint(path), before,
                             "Protected user configuration changed: {}".format(path))

    def launch(self, *args, answers="", explicit_config=True):
        command = [str(self.exe)]
        if explicit_config:
            command.extend(["--config", str(self.settings)])
        command.extend(args)
        result = subprocess.run(command, input=answers, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, encoding="utf-8", errors="strict",
                                cwd=str(self.cwd), env=self.env, timeout=25)
        self.assertEqual(list(self.runtime_temp.glob("CodexProxyTunnel-*")), [],
                         "The EXE left an extracted runtime after exit")
        return result

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_no_profile(self):
        self.assertFalse(self.settings.exists())
        self.assertEqual(list(self.local_appdata.iterdir()), [])
        self.assertEqual(sorted(path.name for path in self.program_dir.iterdir()),
                         [BUILT_EXE.name], "The standalone EXE wrote files beside itself")

    def ssh_fixture(self):
        config = self.base / "来源 ssh config"
        config.write_text(
            "Host gpu-fixture\n"
            "  HostName gpu.example.invalid\n  User scientist\n  Port 2222\n"
            "  LocalForward 8898 localhost:8898\n"
            "Host fallback-fixture\n"
            "  HostName spare.example.invalid\n  User helper\n  Port 22\n",
            encoding="utf-8")
        return config

    def test_help_and_version_are_standalone_and_create_no_files(self):
        result = self.launch("--help", explicit_config=False)
        self.assert_success(result)
        for switch in ("--configure", "--check", "--ssh-help", "--list-hosts", "--start"):
            self.assertIn(switch, result.stdout)
        result = self.launch("--version", explicit_config=False)
        self.assert_success(result)
        self.assertRegex(result.stdout.strip(), r"^CodexProxyTunnel \d+\.\d+\.\d+$")
        self.assert_no_profile()

    def test_invalid_cli_is_rejected_without_creating_files(self):
        invalid_arguments = [
            ("--unknown-option",),
            ("--configure", "--check"),
            ("--proxy-port", "0"),
            ("--proxy-port", "65536"),
            ("--proxy-port", "1082; Write-Output ARGUMENT_EXECUTION_MARKER"),
            ("--ssh-config",),
        ]
        for args in invalid_arguments:
            with self.subTest(args=args):
                result = self.launch(*args, explicit_config=False)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assert_no_profile()

    def test_menu_zero_and_eof_exit_without_hanging_or_creating_profile(self):
        for answers in ("0\n", ""):
            with self.subTest(answers=answers):
                result = self.launch(answers=answers, explicit_config=False)
                self.assert_success(result)
                self.assert_no_profile()

    def test_list_hosts_reads_only_the_explicit_ssh_config(self):
        config = self.ssh_fixture()
        original = config.read_bytes()
        result = self.launch("--list-hosts", "--ssh-config", str(config))
        self.assert_success(result)
        self.assertIn("gpu-fixture", result.stdout)
        self.assertIn("fallback-fixture", result.stdout)
        self.assertEqual(config.read_bytes(), original)
        self.assert_no_profile()

    def test_configure_imports_selected_alias_without_copying_forwards(self):
        config = self.ssh_fixture()
        original = config.read_bytes()
        result = self.launch("--configure", "--ssh-config", str(config), answers="1\n\n")
        self.assert_success(result)
        profile = json.loads(self.settings.read_text(encoding="utf-8-sig"))
        self.assertEqual(profile["server"]["host"], "gpu.example.invalid")
        self.assertEqual(profile["server"]["user"], "scientist")
        self.assertEqual(profile["server"]["port"], 2222)
        self.assertEqual(profile["jumpHosts"], [])
        self.assertEqual(profile["remotePort"], 11082)
        self.assertNotIn("8898", self.settings.read_text(encoding="utf-8-sig"))
        self.assertEqual(config.read_bytes(), original)

    def test_manual_configure_preserves_ordered_jumps_and_literal_output_path(self):
        result = self.launch("--configure", "--manual", answers=(
            "compute.example.invalid\nresearcher\n2244\n\n2\n"
            "entry.example.invalid\nfirstuser\n2201\n\n"
            "inner.example.invalid\nseconduser\n2202\n\n12082\n"))
        self.assert_success(result)
        profile = json.loads(self.settings.read_text(encoding="utf-8-sig"))
        self.assertEqual(profile["server"], dict(host="compute.example.invalid", user="researcher",
                                                  port=2244, identityFile=""))
        self.assertEqual([jump["user"] for jump in profile["jumpHosts"]], ["firstuser", "seconduser"])
        self.assertEqual([jump["port"] for jump in profile["jumpHosts"]], [2201, 2202])
        self.assertEqual(profile["remotePort"], 12082)
        self.assertNotIn("password", self.settings.read_text(encoding="utf-8-sig").lower())
        self.assertEqual(list(self.local_appdata.iterdir()), [])

    def test_relative_configuration_path_is_resolved_against_callers_directory(self):
        result = self.launch("--configure", "--manual", "--config", "relative profile.json",
                             explicit_config=False,
                             answers="gpu.example.invalid\nalice\n22\n\n0\n11082\n")
        self.assert_success(result)
        path = self.cwd / "relative profile.json"
        self.assertEqual(json.loads(path.read_text(encoding="utf-8-sig"))["server"]["user"], "alice")
        self.assert_no_profile()

    def test_manual_relative_identity_path_uses_callers_directory(self):
        key = self.cwd / "relative key.fixture"
        key.write_text("NOT A PRIVATE KEY - path existence fixture only\n", encoding="ascii")
        original = key.read_bytes()
        result = self.launch("--configure", "--manual", answers=(
            "gpu.example.invalid\nalice\n22\nrelative key.fixture\n0\n11082\n"))
        self.assert_success(result)
        profile = json.loads(self.settings.read_text(encoding="utf-8-sig"))
        self.assertEqual(profile["server"]["identityFile"], "relative key.fixture")
        self.assertEqual(key.read_bytes(), original)

    def test_menu_configure_routes_to_alias_selection(self):
        config = self.ssh_fixture()
        result = self.launch("--ssh-config", str(config), answers="2\n1\n\n")
        self.assert_success(result)
        self.assertEqual(json.loads(self.settings.read_text(encoding="utf-8-sig"))["server"]["port"], 2222)

    def test_ssh_help_prints_manual_lookup_commands_without_creating_profile(self):
        result = self.launch("--ssh-help")
        self.assert_success(result)
        self.assertIn("ssh -G YOUR_ALIAS", result.stdout)
        self.assertIn("remote.SSH.configFile", result.stdout)
        self.assert_no_profile()

    def test_menu_help_and_list_routes(self):
        config = self.ssh_fixture()
        for choice, expected in (("4\n", "ssh -G YOUR_ALIAS"), ("5\n", "fallback-fixture")):
            with self.subTest(choice=choice):
                result = self.launch("--ssh-config", str(config), answers=choice)
                self.assert_success(result)
                self.assertIn(expected, result.stdout)
                self.assert_no_profile()

    def test_start_without_profile_fails_before_proxy_detection_or_ssh(self):
        result = self.launch("--start", "--no-prompt")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("No valid profile", result.stdout)
        self.assertNotIn("http://127.0.0.1:", result.stdout)
        self.assert_no_profile()

    def test_password_in_profile_is_rejected_without_echoing_it(self):
        profile = dict(version=1,
                       server=dict(host="gpu.example.invalid", user="alice", port=22,
                                   identityFile="", password="SENSITIVE_FIXTURE_MUST_NOT_ECHO"),
                       jumpHosts=[], remotePort=11082, checkIntervalSeconds=60)
        self.settings.write_text(json.dumps(profile), encoding="utf-8")
        original = self.settings.read_bytes()
        result = self.launch("--start", "--no-prompt")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Do not store passwords", result.stdout)
        self.assertNotIn("SENSITIVE_FIXTURE_MUST_NOT_ECHO", result.stdout + result.stderr)
        self.assertEqual(self.settings.read_bytes(), original)

    def test_check_rejects_reserved_non_listening_local_port_without_ssh(self):
        # A dual-stack socket reserves the same port on both local address
        # families; neither candidate can reach an unrelated listening service.
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as reserve:
            reserve.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            reserve.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            reserve.bind(("::", 0))
            port = str(reserve.getsockname()[1])
            result = self.launch("--check", "--no-prompt", "--proxy-port", port)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("No SSH tunnel was started", result.stdout)
        self.assert_no_profile()

    def test_terminating_exe_closes_its_waiting_powershell_child(self):
        # Force-closing a parent cannot execute its finally block. This test
        # verifies process ownership, while TemporaryDirectory owns any remaining
        # extraction files; normal-exit cleanup is checked by every launch().
        process = subprocess.Popen(
            [str(self.exe), "--configure", "--manual", "--config", str(self.settings)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            encoding="utf-8", errors="strict", cwd=str(self.cwd), env=self.env)
        ready = threading.Event()
        output = []
        child_api, child_handle = None, None

        def read_output():
            for line in process.stdout:
                output.append(line)
                if "目标服务器" in line:
                    ready.set()

        reader = threading.Thread(target=read_output, daemon=True)
        reader.start()
        try:
            # The wizard header proves the child was resumed and assigned to
            # its job, avoiding a race with CREATE_SUSPENDED initialization.
            self.assertTrue(ready.wait(10), "Manual wizard did not start: " + "".join(output))
            child_api, child_handle = owned_powershell_handle(process.pid)
            process.terminate()
            process.wait(timeout=5)
            self.assertEqual(child_api.WaitForSingleObject(child_handle, 5000), 0,
                             "PowerShell remained alive after its EXE parent exited")
            self.assertFalse(self.settings.exists())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            if child_handle:
                if child_api.WaitForSingleObject(child_handle, 0) != 0:
                    child_api.TerminateProcess(child_handle, 99)
                    child_api.WaitForSingleObject(child_handle, 5000)
                child_api.CloseHandle(child_handle)
            process.stdin.close()
            reader.join(timeout=5)
            process.stdout.close()


if __name__ == "__main__":
    unittest.main()
