"""Offline behavior checks for the POSIX remote monitor; Python standard library only.

Run: python -m unittest discover -s tests -p test_remote_monitor.py -v
Uses an existing POSIX sh, including Git for Windows. No request reaches a network.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "remote-monitor.sh"
GIT_BASH = Path(r"C:\Program Files\Git\bin\bash.exe")
BASH = str(GIT_BASH) if GIT_BASH.is_file() else shutil.which("bash")


def shell_path(path):
    value = str(Path(path).resolve()).replace("\\", "/")
    if os.name == "nt" and len(value) > 2 and value[1] == ":":
        return "/" + value[0].lower() + value[2:]
    return value


@unittest.skipUnless(BASH, "Requires existing bash (Git for Windows is supported)")
class RemoteMonitorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="monitor test ")
        self.fixture = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.write_tool("date", "printf '%s\\n' '2026-10-22T12:00:00Z'\n")
        self.write_tool("sleep", "exit 0\n")

    def write_tool(self, name, body):
        target = self.fixture / name
        target.write_bytes(("#!/bin/sh\n" + body).encode("utf-8"))
        target.chmod(0o755)

    def fake_curl(self, results):
        cases = []
        for index, (http, exit_code) in enumerate(results, start=1):
            cases.append(
                f"{index}) printf '%s' '{http}'; exit {exit_code} ;;"
            )
        http, exit_code = results[-1]
        self.write_tool(
            "curl",
            "n=0\n"
            'if [ -f "$FIXTURE/calls" ]; then read -r n < "$FIXTURE/calls"; fi\n'
            "n=$((n + 1))\n"
            'printf "%s\\n" "$n" > "$FIXTURE/calls"\n'
            'printf "%s\\n" "$@" > "$FIXTURE/args"\n'
            'case "$n" in\n' + "\n".join(cases) + "\n"
            f"*) printf '%s' '{http}'; exit {exit_code} ;;\n"
            "esac\n",
        )

    def fake_ss(self, output, exit_code=0):
        self.write_tool(
            "ss",
            'printf "%s\\n" "$@" > "$FIXTURE/ss-args"\n'
            + "printf '%s' '" + output.replace("'", "'\\''") + "'\n"
            + f"exit {exit_code}\n",
        )

    def disconnect_after_sleeps(self, count):
        self.write_tool(
            "sleep",
            "n=0\n"
            'if [ -f "$FIXTURE/sleeps" ]; then read -r n < "$FIXTURE/sleeps"; fi\n'
            "n=$((n + 1))\n"
            'printf "%s\\n" "$n" > "$FIXTURE/sleeps"\n'
            f'if [ "$n" -ge {count} ]; then kill -HUP "$PPID"; fi\n'
            "exit 0\n",
        )

    def run_monitor(self, *args, streamed=False):
        env = os.environ.copy()
        env["FIXTURE"] = shell_path(self.fixture)
        # Set PATH after Bash startup, so Windows/MSYS cannot add real curl.
        sh_args = ["-s", "--", *args] if streamed else [shell_path(SCRIPT), *args]
        return subprocess.run(
            [BASH, "--noprofile", "--norc", "-c",
             'PATH="$1"; export PATH; shift; exec /bin/sh "$@"', "monitor-test",
             shell_path(self.fixture), *sh_args],
            input=SCRIPT.read_text(encoding="utf-8") if streamed else "",
            capture_output=True, text=True, env=env, timeout=8,
        )

    def assert_no_ready(self, result):
        self.assertNotIn("TUNNEL_READY", result.stdout)
        self.assertNotIn("TUNNEL_RECOVERED", result.stdout)

    def test_401_confirms_target_and_uses_explicit_safe_curl_arguments(self):
        self.fake_curl([("401", 0)])
        result = self.run_monitor("18080", "60", "once")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TUNNEL_READY", result.stdout)
        self.assertIn("2026-10-22T12:00:00Z", result.stdout)
        self.assertIn("login/model inference not tested", result.stdout)
        args = (self.fixture / "args").read_text().splitlines()
        self.assertEqual(args[0], "-q")
        for flag, value in [
            ("--noproxy", ""), ("--proxy", "http://127.0.0.1:18080"),
            ("--connect-timeout", "5"), ("--max-time", "15"),
            ("--output", "/dev/null"), ("--write-out", "%{http_code}"),
        ]:
            self.assertIn(flag, args)
            self.assertEqual(args[args.index(flag) + 1], value)
        self.assertEqual(args[-1], "https://api.openai.com/v1/models")
        self.assertNotIn("-k", args)
        self.assertNotIn("--insecure", args)

    def test_target_2xx_is_ready(self):
        for http in ("200", "204", "299"):
            with self.subTest(http=http):
                (self.fixture / "calls").unlink(missing_ok=True)
                self.fake_curl([(http, 0)])
                result = self.run_monitor("18080", "60", "once")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("TUNNEL_READY", result.stdout)

    def test_loopback_listener_addresses_allow_target_check(self):
        self.fake_curl([("401", 0)])
        for address in ("127.0.0.1", "[::1]", "::1"):
            with self.subTest(address=address):
                self.fake_ss(f"LISTEN 0 128 {address}:18080 0.0.0.0:*\n")
                result = self.run_monitor("18080", "60", "once")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("TUNNEL_READY", result.stdout)
                self.assertNotIn("TUNNEL_BIND_UNSAFE", result.stdout)
                self.assertNotIn("TUNNEL_BIND_UNVERIFIED", result.stdout)
                self.assertEqual((self.fixture / "ss-args").read_text().splitlines(), ["-H", "-ltn"])

    def test_wildcard_or_nonloopback_listener_aborts_before_curl(self):
        self.fake_curl([("401", 0)])
        for address in ("0.0.0.0", "[::]", "::", "*", "192.0.2.4", "[2001:db8::1]"):
            with self.subTest(address=address):
                self.fake_ss(f"LISTEN 0 128 {address}:18080 0.0.0.0:*\n")
                result = self.run_monitor("18080", "60", "once")
                self.assertEqual(result.returncode, 78, result.stderr)
                self.assertIn("TUNNEL_BIND_UNSAFE", result.stdout)
                self.assertIn("TUNNEL_STOPPED", result.stdout)
                self.assert_no_ready(result)
                self.assertFalse((self.fixture / "calls").exists())

    def test_loopback_does_not_hide_an_unsafe_listener_on_same_port(self):
        self.fake_curl([("401", 0)])
        self.fake_ss("LISTEN 0 128 127.0.0.1:18080 0.0.0.0:*\n"
                     "LISTEN 0 128 [::]:18080 [::]:*\n")
        result = self.run_monitor("18080", "60", "once")
        self.assertEqual(result.returncode, 78, result.stderr)
        self.assertIn("TUNNEL_BIND_UNSAFE", result.stdout)
        self.assertFalse((self.fixture / "calls").exists())

    def test_missing_ss_notes_binding_unverified_but_still_checks_target(self):
        self.fake_curl([("401", 0)])
        result = self.run_monitor("18080", "60", "once")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TUNNEL_BIND_UNVERIFIED", result.stdout)
        self.assertIn("TUNNEL_READY", result.stdout)
        self.assertNotIn("TUNNEL_UNVERIFIED", result.stdout)

    def test_failed_ss_notes_binding_unverified_and_ignores_partial_output(self):
        self.fake_curl([("401", 0)])
        self.fake_ss("LISTEN 0 128 0.0.0.0:18080 0.0.0.0:*\n", exit_code=1)
        result = self.run_monitor("18080", "60", "once")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TUNNEL_BIND_UNVERIFIED", result.stdout)
        self.assertNotIn("TUNNEL_BIND_UNSAFE", result.stdout)
        self.assertIn("TUNNEL_READY", result.stdout)

    def test_no_matching_listener_notes_binding_unverified(self):
        self.fake_curl([("401", 0)])
        for output in ("", "LISTEN 0 128 0.0.0.0:18081 0.0.0.0:*\n"):
            with self.subTest(output=output):
                self.fake_ss(output)
                result = self.run_monitor("18080", "60", "once")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("TUNNEL_BIND_UNVERIFIED", result.stdout)
                self.assertNotIn("TUNNEL_BIND_UNSAFE", result.stdout)
                self.assertIn("TUNNEL_READY", result.stdout)

    def test_unrelated_wildcard_port_is_ignored_when_target_is_loopback(self):
        self.fake_curl([("401", 0)])
        self.fake_ss("LISTEN 0 128 0.0.0.0:18081 0.0.0.0:*\n"
                     "LISTEN 0 128 127.0.0.1:18080 0.0.0.0:*\n")
        result = self.run_monitor("18080", "60", "once")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("TUNNEL_BIND_UNSAFE", result.stdout)
        self.assertNotIn("TUNNEL_BIND_UNVERIFIED", result.stdout)
        self.assertIn("TUNNEL_READY", result.stdout)

    def test_403_is_degraded_and_does_not_claim_access(self):
        self.fake_curl([("403", 0)])
        result = self.run_monitor("18080", "60", "once")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("TUNNEL_DEGRADED", result.stdout)
        self.assertIn("TLS/HTTP reachable", result.stdout)
        self.assertIn("route/account access not verified", result.stdout)
        self.assert_no_ready(result)
        self.assertEqual((self.fixture / "calls").read_text().strip(), "2")

    def test_tls_failure_rejects_even_a_connect_200(self):
        self.fake_curl([("200", 35)])
        result = self.run_monitor("18080", "60", "once")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("curl_exit=35", result.stdout)
        self.assertIn("TUNNEL_DEGRADED", result.stdout)
        self.assert_no_ready(result)

    def test_other_or_malformed_target_http_is_degraded(self):
        for http in ("000", "301", "407", "500", "200401", "200\n401"):
            with self.subTest(http=http):
                (self.fixture / "calls").unlink(missing_ok=True)
                # Multiline response is intentional; no interpolation from users.
                self.fake_curl([(http, 0)])
                result = self.run_monitor("18080", "60", "once")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assert_no_ready(result)

    def test_transient_startup_failure_recovers_with_second_attempt(self):
        self.fake_curl([("000", 7), ("401", 0)])
        result = self.run_monitor("18080", "60", "once")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TUNNEL_DEGRADED", result.stdout)
        self.assertIn("TUNNEL_RECOVERED", result.stdout)
        self.assertIn("TUNNEL_READY", result.stdout)
        self.assertLess(result.stdout.index("TUNNEL_DEGRADED"), result.stdout.index("TUNNEL_READY"))

    def test_missing_curl_is_unverified(self):
        result = self.run_monitor("18080", "60", "once")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("TUNNEL_UNVERIFIED", result.stdout)
        self.assertIn("curl is missing", result.stdout)
        self.assert_no_ready(result)

    def test_missing_curl_keeps_tunnel_open_until_hangup(self):
        self.disconnect_after_sleeps(2)
        result = self.run_monitor("18080", "60")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TUNNEL_UNVERIFIED", result.stdout)
        self.assertIn("TUNNEL_STOPPED", result.stdout)
        self.assertEqual((self.fixture / "sleeps").read_text().strip(), "2")
        self.assert_no_ready(result)

    def test_monitor_continues_after_stdin_eof_and_recovers(self):
        self.fake_curl([("000", 7), ("000", 7), ("401", 0)])
        self.disconnect_after_sleeps(3)
        result = self.run_monitor("18080", "4")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TUNNEL_RECOVERED", result.stdout)
        self.assertIn("TUNNEL_STOPPED", result.stdout)
        self.assertEqual((self.fixture / "calls").read_text().strip(), "3")

    def test_ready_monitor_degrades_then_recovers_without_restarting(self):
        self.fake_curl([("401", 0), ("403", 0), ("401", 0)])
        self.disconnect_after_sleeps(3)
        result = self.run_monitor("18080", "4")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("TUNNEL_READY"), 1)
        self.assertIn("TUNNEL_DEGRADED", result.stdout)
        self.assertIn("TUNNEL_RECOVERED", result.stdout)
        self.assertIn("TUNNEL_STOPPED", result.stdout)

    def test_script_streamed_over_stdin_remains_alive_after_eof(self):
        self.fake_curl([("401", 0)])
        self.disconnect_after_sleeps(2)
        result = self.run_monitor("18080", "4", streamed=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TUNNEL_READY", result.stdout)
        self.assertIn("TUNNEL_HEARTBEAT HEALTHY", result.stdout)
        self.assertIn("TUNNEL_STOPPED", result.stdout)
        self.assertEqual((self.fixture / "calls").read_text().strip(), "2")

    def test_rejects_invalid_arguments_before_checking(self):
        self.fake_curl([("401", 0)])
        invalid = [(), ("0", "60"), ("65536", "60"), ("-1", "60"),
                   ("22;id", "60"), ("08080", "60"), ("18080", "3"),
                   ("18080", "86401"), ("18080", "x"),
                   ("18080", "60", "unknown"), ("18080", "60", "once", "extra")]
        for args in invalid:
            with self.subTest(args=args):
                result = self.run_monitor(*args)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn("Usage:", result.stderr)
                self.assert_no_ready(result)
        self.assertFalse((self.fixture / "calls").exists())

    def test_shell_source_is_lf_without_bom_and_parses(self):
        content = SCRIPT.read_bytes()
        self.assertFalse(content.startswith(b"\xef\xbb\xbf"))
        self.assertNotIn(b"\r\n", content)
        result = subprocess.run(
            [BASH, "--noprofile", "--norc", "-n", shell_path(SCRIPT)],
            capture_output=True, text=True, timeout=8,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
