"""Offline integration tests for remote-only VS Code JSONC configuration.

Uses the existing Node runtime and optionally Git Bash. No SSH/network is used.
Run: python -m unittest discover -s tests -p test_remote_vscode_config.py -v
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
JAVASCRIPT = ROOT / "remote-vscode-config.js"
SHELL = ROOT / "remote-vscode-config.sh"
NODE = shutil.which("node")
GIT_BASH = Path(r"C:\Program Files\Git\bin\bash.exe")
BASH = str(GIT_BASH) if GIT_BASH.is_file() else shutil.which("bash")
BRIDGE = r"""
const fs = require('fs');
const api = require(process.argv[1]);
const request = JSON.parse(fs.readFileSync(0, 'utf8'));
try {
  let result;
  if (request.action === 'patch') result = api.patchSettings(request.text, request.port);
  else if (request.action === 'discover') result = api.discoverDirectories(request.home, request.environment || {}, request.proc || null);
  else {
    const rename = fs.renameSync;
    let calls = 0;
    if (request.failRename) fs.renameSync = function (from, to) {
      if (++calls === request.failRename) { const e = new Error('fixture'); e.code = 'EACCES'; throw e; }
      return rename.apply(fs, arguments);
    };
    if (request.concurrent) {
      const write = fs.writeFileSync;
      let once = false;
      fs.writeFileSync = function (fd) {
        const result = write.apply(fs, arguments);
        if (!once && typeof fd === 'number' && Buffer.isBuffer(arguments[1]) && arguments[1].toString().includes('http.proxy')) {
          once = true; write(request.concurrent, '{"editor.fontSize":99}\n');
        }
        return result;
      };
    }
    result = api.configureDirectories(request.directories, request.port);
  }
  process.stdout.write(JSON.stringify({ok:true,result:result}));
} catch(e) { process.stdout.write(JSON.stringify({ok:false,code:e.code || 'unknown'})); }
"""


@unittest.skipUnless(NODE, "Requires an existing Node.js runtime")
class RemoteVscodeConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="remote vscode test ")
        self.home = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def invoke(self, **request):
        request.setdefault("port", 11082)
        env = os.environ.copy()
        env.pop("NODE_OPTIONS", None)
        result = subprocess.run([NODE, "-e", BRIDGE, str(JAVASCRIPT)], input=json.dumps(request), capture_output=True, text=True, encoding='utf-8', timeout=10, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def patch(self, text, port=11082):
        result = self.invoke(action="patch", text=text, port=port)
        self.assertTrue(result["ok"], result)
        return result["result"]

    def machine(self, name=".vscode-server", content=None):
        directory = self.home / name / "data" / "Machine"
        directory.mkdir(parents=True)
        if content is not None:
            (directory / "settings.json").write_bytes(content.encode("utf-8") if isinstance(content, str) else content)
        return directory

    def configure(self, *directories, **kwargs):
        return self.invoke(action="configure", directories=[str(p) for p in directories], **kwargs)

    def test_empty_object(self):
        value = json.loads(self.patch("{}"))
        self.assertEqual(value, {"http.proxy": "http://127.0.0.1:11082", "http.useLocalProxyConfiguration": False})

    def test_single_line_existing_setting(self):
        value = json.loads(self.patch('{"editor.fontSize":16}'))
        self.assertEqual(value["editor.fontSize"], 16)

    def test_comments_trailing_commas_and_nested_strings_preserved(self):
        text = '{\n  // user note\n  "editor.fontFamily": "a // b /* c */",\n  "files.associations": {"*.abc": "json",}, // keep\n}\n'
        result = self.patch(text)
        self.assertTrue(result.startswith(text[:-2]))
        self.assertIn('"files.associations": {"*.abc": "json",}, // keep', result)
        self.assertEqual(self.patch(result), result)

    def test_existing_owned_values_only_replaced(self):
        text = '{ /* begin */ "http.proxy" /* x */ : "http://old", "editor.fontSize": 15, "http.useLocalProxyConfiguration": true /* tail */ }'
        result = self.patch(text)
        expected = text.replace('"http://old"', '"http://127.0.0.1:11082"').replace(': true', ': false')
        self.assertEqual(result, expected)

    def test_duplicate_owned_keys_all_updated(self):
        text = '{"http.proxy":"old","http.proxy":"new","http.useLocalProxyConfiguration":true,"http.useLocalProxyConfiguration":true}'
        result = self.patch(text)
        self.assertEqual(result.count('"http://127.0.0.1:11082"'), 2)
        self.assertEqual(result.count(':false'), 2)

    def test_escaped_owned_key_is_recognized(self):
        result = self.patch('{"http.\\u0070roxy":"old"}')
        self.assertEqual(result.count('127.0.0.1'), 1)
        self.assertIn('http.\\u0070roxy', result)

    def test_nested_proxy_setting_untouched(self):
        result = self.patch('{"nested":{"http.proxy":"http://keep"}}')
        self.assertIn('"nested":{"http.proxy":"http://keep"}', result)

    def test_bom_crlf_tabs_retained(self):
        text = '\ufeff{\r\n\t"editor.fontSize": 15\r\n}\r\n'
        result = self.patch(text)
        self.assertTrue(result.startswith('\ufeff{\r\n\t'))
        self.assertNotIn('\n', result.replace('\r\n', ''))
        self.assertIn('\t"http.proxy"', result)

    def test_comments_only_object(self):
        result = self.patch('{\n// keep this note\n}\n')
        self.assertIn('// keep this note\n', result)
        self.assertEqual(self.patch(result), result)

    def test_comma_precedes_end_of_line_comment(self):
        result = self.patch('{\n "editor.fontSize": 15 // keep\n}')
        self.assertIn('15, // keep', result)

    def test_invalid_jsonc_refused(self):
        for text in ('', '[]', '{"x":}', '{"x":01}', '{"x":1,,}', '{} trailing', '{/* unclosed', '{"x": "bad\nstring"}', '{"x": NaN}', '{"x":truefalse}', '{\u00a0"x":1}'):
            with self.subTest(text=text):
                self.assertEqual(self.invoke(action="patch", text=text)["code"], "malformed_settings")

    def test_excessive_nesting_refused(self):
        result = self.invoke(action="patch", text='{"x":' + '[' * 130 + '0' + ']' * 130 + '}')
        self.assertEqual(result["code"], "malformed_settings")

    def test_invalid_port_refused(self):
        for port in (0, 22, 1023, 65536, "011082", "11082;echo bad", "11082\n"):
            with self.subTest(port=port):
                self.assertEqual(self.invoke(action="patch", text="{}", port=port)["code"], "invalid_port")

    def test_writes_backup_exactly_and_preserves_unrelated(self):
        text = '\ufeff{\r\n  // credential stays local on server\r\n  "other.secret":"DO_NOT_LOG",\r\n}\r\n'
        directory = self.machine(content=text)
        result = self.configure(directory)
        self.assertEqual(result, {"ok": True, "result": {"changed": 1, "targets": 1}})
        backups = list(directory.glob('settings.json.codex-tunnel-backup-*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), text.encode('utf-8'))
        self.assertIn('DO_NOT_LOG', (directory / 'settings.json').read_text(encoding='utf-8'))
        self.assertNotIn('DO_NOT_LOG', json.dumps(result))

    def test_idempotent_does_not_add_backup(self):
        directory = self.machine(content='{}')
        self.configure(directory)
        before = (directory / 'settings.json').stat().st_mtime_ns
        result = self.configure(directory)
        self.assertEqual(result['result']['changed'], 0)
        self.assertEqual(len(list(directory.glob('settings.json.codex-tunnel-backup-*'))), 1)
        self.assertEqual((directory / 'settings.json').stat().st_mtime_ns, before)

    def test_missing_settings_created_with_no_backup(self):
        directory = self.machine()
        self.assertTrue(self.configure(directory)['ok'])
        self.assertEqual(len(list(directory.glob('settings.json.codex-tunnel-backup-*'))), 0)
        self.assertFalse(list(directory.glob('.codex-tunnel-*')))

    def test_malformed_second_target_leaves_first_unchanged(self):
        first = self.machine('.vscode-server', '{}')
        second = self.machine('.vscode-server-insiders', '{"x":}')
        result = self.configure(first, second)
        self.assertEqual(result['code'], 'malformed_settings')
        self.assertEqual((first / 'settings.json').read_text(), '{}')
        self.assertFalse(list(first.glob('.codex-tunnel-*')))
        self.assertFalse(list(second.glob('.codex-tunnel-*')))

    def test_rename_failure_rolls_back_previous_target(self):
        first = self.machine('.vscode-server', '{"a":1}')
        second = self.machine('.vscode-server-insiders', '{"b":2}')
        result = self.configure(first, second, failRename=2)
        self.assertFalse(result['ok'])
        self.assertEqual((first / 'settings.json').read_text(), '{"a":1}')
        self.assertEqual((second / 'settings.json').read_text(), '{"b":2}')
        self.assertFalse(list(first.glob('.codex-tunnel-*')))
        self.assertFalse(list(second.glob('.codex-tunnel-*')))

    def test_concurrent_external_edit_not_overwritten(self):
        directory = self.machine(content='{}')
        result = self.configure(directory, concurrent=str(directory / 'settings.json'))
        self.assertEqual(result['code'], 'concurrent_change')
        self.assertEqual(json.loads((directory / 'settings.json').read_text()), {'editor.fontSize': 99})

    def test_existing_lock_blocks_without_modification(self):
        directory = self.machine(content='{}')
        lock = directory / '.codex-tunnel-vscode.lock'
        lock.write_text('{"pid":123}')
        self.assertEqual(self.configure(directory)['code'], 'concurrent_change')
        self.assertTrue(lock.exists())
        self.assertEqual((directory / 'settings.json').read_text(), '{}')

    def test_large_settings_not_read_or_modified(self):
        directory = self.machine(content=b' ' * (1024 * 1024 + 1))
        self.assertEqual(self.configure(directory)['code'], 'settings_too_large')
        self.assertEqual((directory / 'settings.json').stat().st_size, 1024 * 1024 + 1)

    def test_invalid_utf8_refused(self):
        directory = self.machine(content=b'{"x":"\xff"}')
        self.assertEqual(self.configure(directory)['code'], 'malformed_settings')

    def test_hardlinked_settings_refused(self):
        directory = self.machine(content='{}')
        outside = self.home / 'outside.json'
        os.link(directory / 'settings.json', outside)
        self.assertEqual(self.configure(directory)['code'], 'unsafe_path')
        self.assertEqual(outside.read_text(), '{}')

    def test_symlinked_settings_refused(self):
        directory = self.machine()
        outside = self.home / 'outside.json'
        outside.write_text('{}')
        try:
            (directory / 'settings.json').symlink_to(outside)
        except OSError as error:
            self.skipTest('OS disallows unprivileged symlinks: ' + str(error))
        self.assertEqual(self.configure(directory)['code'], 'unsafe_path')
        self.assertEqual(outside.read_text(), '{}')

    def test_linked_parent_directory_refused(self):
        outside = self.home / 'outside'
        outside.mkdir()
        (outside / 'settings.json').write_text('{}')
        link = self.home / 'linked-machine'
        creation = subprocess.run([NODE, '-e', "require('fs').symlinkSync(process.argv[1],process.argv[2],process.platform==='win32'?'junction':'dir')", str(outside), str(link)], capture_output=True, timeout=5)
        if creation.returncode:
            self.skipTest('OS disallows directory links')
        self.assertEqual(self.configure(link)['code'], 'unsafe_path')
        self.assertEqual((outside / 'settings.json').read_text(), '{}')

    def test_discovery_standard_and_insiders(self):
        stable, insiders = self.machine(), self.machine('.vscode-server-insiders')
        result = self.invoke(action='discover', home=str(self.home))
        self.assertEqual(set(result['result']), {str(stable), str(insiders)})

    def test_discovery_agent_folder(self):
        custom = self.machine('custom-server')
        result = self.invoke(action='discover', home=str(self.home), environment={'VSCODE_AGENT_FOLDER': str(custom.parent.parent)})
        self.assertEqual(result['result'], [str(custom)])

    def test_discovery_running_custom_data_path(self):
        custom = self.home / 'custom-data'
        custom.mkdir()
        proc = self.home / 'fake-proc' / '123'
        proc.mkdir(parents=True)
        (proc / 'cmdline').write_bytes(('node\0/custom/bin/commit/out/server-main.js\0--server-data-dir\0' + str(custom) + '\0--connection-token\0NEVER_LOG\0').encode())
        result = self.invoke(action='discover', home=str(self.home), proc=str(proc.parent))
        self.assertEqual(result['result'], [str(custom / 'data' / 'Machine')])
        self.assertNotIn('NEVER_LOG', json.dumps(result))

    def test_active_user_data_override_does_not_write_inactive_default(self):
        standard = self.machine()
        custom = self.home / 'active-user-data'
        custom.mkdir()
        proc = self.home / 'fake-proc' / '123'
        proc.mkdir(parents=True)
        main = str(standard.parent.parent).replace('\\', '/') + '/cli/servers/Stable-fixture/server/out/server-main.js'
        (proc / 'cmdline').write_bytes(('node\0' + main + '\0--server-data-dir=' + str(standard.parent.parent) + '\0--user-data-dir=' + str(custom) + '\0').encode())
        result = self.invoke(action='discover', home=str(self.home), proc=str(proc.parent))
        self.assertEqual(result['result'], [str(custom / 'Machine')])

    def test_relative_custom_process_path_fails_without_guessing(self):
        proc = self.home / 'fake-proc' / '123'
        proc.mkdir(parents=True)
        (proc / 'cmdline').write_bytes(b'node\0/custom/bin/commit/out/server-main.js\0--server-data-dir\0relative-root\0')
        result = self.invoke(action='discover', home=str(self.home), proc=str(proc.parent))
        self.assertEqual(result['code'], 'discovery_failed')

    def test_no_server_root_is_actionable(self):
        result = self.invoke(action='discover', home=str(self.home))
        self.assertEqual(result['result'], [])
        self.assertEqual(self.configure()['code'], 'vscode_not_found')

    def test_local_codex_and_vscode_files_unchanged(self):
        local_codex = self.home / 'local-codex.toml'
        local_vscode = self.home / 'local-vscode.json'
        local_codex.write_text('model = "keep"')
        local_vscode.write_text('{"http.proxy":"keep"}')
        directory = self.machine(content='{}')
        self.assertTrue(self.configure(directory)['ok'])
        self.assertEqual(local_codex.read_text(), 'model = "keep"')
        self.assertEqual(local_vscode.read_text(), '{"http.proxy":"keep"}')

    @unittest.skipUnless(BASH, 'Requires bash')
    def test_streamed_shell_runs_real_node(self):
        directory = self.machine(content='{"editor.fontSize":14}')
        script = SHELL.read_text(encoding='utf-8').replace('__CODEX_TUNNEL_VSCODE_JS__', JAVASCRIPT.read_text(encoding='utf-8'))
        env = os.environ.copy()
        env['HOME'] = str(self.home)
        env['USERPROFILE'] = str(self.home)
        env.pop('VSCODE_AGENT_FOLDER', None)
        result = subprocess.run([BASH, '--noprofile', '--norc', '-s', '--', '11082'], input=script, text=True, encoding='utf-8', capture_output=True, env=env, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.strip(), 'VSCODE_CONFIGURED changed=1 targets=1')
        self.assertEqual(json.loads((directory / 'settings.json').read_text())['editor.fontSize'], 14)

    @unittest.skipUnless(BASH, 'Requires bash')
    def test_shell_invalid_port(self):
        result = subprocess.run([BASH, '--noprofile', '--norc', '-s', '--', '0'], input=SHELL.read_text(encoding='utf-8'), text=True, capture_output=True, timeout=5)
        self.assertEqual(result.stdout.strip(), 'VSCODE_ERROR code=invalid_port')
        self.assertNotEqual(result.returncode, 0)

    @unittest.skipUnless(BASH, 'Requires bash')
    def test_missing_node_has_fixed_actionable_error(self):
        tools = self.home / 'empty-tools'
        tools.mkdir()
        env = os.environ.copy()
        env['HOME'] = str(self.home)
        env.pop('VSCODE_AGENT_FOLDER', None)
        tools_posix = str(tools).replace('\\', '/')
        if os.name == 'nt':
            tools_posix = '/' + tools_posix[0].lower() + tools_posix[2:]
        result = subprocess.run([BASH, '--noprofile', '--norc', '-c', 'PATH="$1"; export PATH; exec /bin/sh -s -- 11082', 'fixture', tools_posix], input=SHELL.read_text(encoding='utf-8'), text=True, encoding='utf-8', capture_output=True, env=env, timeout=10)
        self.assertEqual(result.stdout.strip(), 'VSCODE_ERROR code=runtime_missing')
        self.assertNotEqual(result.returncode, 0)

    @unittest.skipUnless(BASH, 'Requires bash')
    def test_incompatible_node_has_fixed_actionable_error(self):
        tools = self.home / 'old-tools'
        tools.mkdir()
        node = tools / 'node'
        node.write_text('#!/bin/sh\nexit 1\n', encoding='utf-8')
        node.chmod(0o755)
        env = os.environ.copy()
        env['HOME'] = str(self.home)
        env.pop('VSCODE_AGENT_FOLDER', None)
        tools_posix = str(tools).replace('\\', '/')
        if os.name == 'nt':
            tools_posix = '/' + tools_posix[0].lower() + tools_posix[2:]
        result = subprocess.run([BASH, '--noprofile', '--norc', '-c', 'PATH="$1"; export PATH; exec /bin/sh -s -- 11082', 'fixture', tools_posix], input=SHELL.read_text(encoding='utf-8'), text=True, encoding='utf-8', capture_output=True, env=env, timeout=10)
        self.assertEqual(result.stdout.strip(), 'VSCODE_ERROR code=unsupported_runtime')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
