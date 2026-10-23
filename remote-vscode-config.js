'use strict';
// Executed only on the selected remote account. No package installation is needed.
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const MAX_BYTES = 1024 * 1024;

function fail(code) { const error = new Error(code); error.code = code; throw error; }
function portValue(value) {
    if (!/^[1-9][0-9]{3,4}$/.test(String(value)) || Number(value) < 1024 || Number(value) > 65535) fail('invalid_port');
    return Number(value);
}

// A small validating JSONC parser records source offsets, rather than serializing
// the document. Comments, formatting, trailing commas and unrelated settings stay.
function parseDocument(text) {
    let at = text.charCodeAt(0) === 0xfeff ? 1 : 0;
    const properties = [];
    function trivia() {
        while (at < text.length) {
            if (/[ \t\r\n]/.test(text[at])) { at++; continue; }
            if (text.slice(at, at + 2) === '//') { at += 2; while (at < text.length && text[at] !== '\n' && text[at] !== '\r') at++; continue; }
            if (text.slice(at, at + 2) === '/*') {
                const end = text.indexOf('*/', at + 2);
                if (end < 0) fail('malformed_settings');
                at = end + 2; continue;
            }
            break;
        }
    }
    function string() {
        const start = at++;
        while (at < text.length) {
            if (text[at] === '\\') { at += 2; continue; }
            if (text[at++] === '"') {
                try { return JSON.parse(text.slice(start, at)); } catch (_) { fail('malformed_settings'); }
            }
        }
        fail('malformed_settings');
    }
    function value(depth, top) {
        if (depth > 128) fail('malformed_settings');
        trivia();
        if (text[at] === '"') { string(); return; }
        if (text[at] === '{' || text[at] === '[') {
            const object = text[at++] === '{', closing = object ? '}' : ']';
            let trailing = false, lastEnd = at;
            trivia();
            while (text[at] !== closing) {
                let key, keyStart;
                if (object) {
                    if (text[at] !== '"') fail('malformed_settings');
                    keyStart = at; key = string(); trivia();
                    if (text[at++] !== ':') fail('malformed_settings');
                    trivia();
                }
                const start = at;
                value(depth + 1, false);
                lastEnd = at;
                if (top) properties.push({ key: key, keyStart: keyStart, start: start, end: at });
                trivia();
                if (text[at] === closing) { trailing = false; break; }
                if (text[at++] !== ',') fail('malformed_settings');
                trivia(); trailing = text[at] === closing;
            }
            const close = at++;
            if (top) return { properties: properties, close: close, lastEnd: lastEnd, trailing: trailing };
            return;
        }
        const match = /^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/.exec(text.slice(at));
        if (!match) fail('malformed_settings');
        at += match[0].length;
    }
    trivia();
    if (text[at] !== '{') fail('malformed_settings');
    const result = value(0, true);
    trivia();
    if (at !== text.length) fail('malformed_settings');
    return result;
}

function patchSettings(text, port) {
    port = portValue(port);
    const tree = parseDocument(text);
    const desired = { 'http.proxy': JSON.stringify('http://127.0.0.1:' + port), 'http.useLocalProxyConfiguration': 'false' };
    const seen = Object.create(null), edits = [];
    tree.properties.forEach(function (property) {
        if (!Object.prototype.hasOwnProperty.call(desired, property.key)) return;
        seen[property.key] = true;
        // Update all duplicate owned keys so both first-wins and last-wins
        // readers agree. Duplicate unrelated properties are left byte-for-byte.
        const replacement = desired[property.key];
        if (text.slice(property.start, property.end) !== replacement) edits.push({ start: property.start, end: property.end, text: replacement });
    });
    const missing = Object.keys(desired).filter(function (key) { return !seen[key]; });
    if (missing.length) {
        const newline = text.indexOf('\r\n') >= 0 ? '\r\n' : '\n';
        let indent = '  ';
        for (const property of tree.properties) {
            const start = text.lastIndexOf('\n', property.keyStart - 1) + 1;
            const prefix = text.slice(start, property.keyStart);
            if (/^[\t ]+$/.test(prefix)) { indent = prefix; break; }
        }
        const lineStart = text.lastIndexOf('\n', tree.close - 1) + 1;
        const closePrefix = text.slice(lineStart, tree.close);
        const position = /^[\t ]*$/.test(closePrefix) ? lineStart : tree.close;
        const closeIndent = position === lineStart ? closePrefix : '';
        let added = (position > 0 && text[position - 1] === '\n' ? '' : newline);
        added += missing.map(function (key) { return indent + JSON.stringify(key) + ': ' + desired[key]; }).join(',' + newline);
        if (tree.trailing) added += ',';
        added += newline;
        // Existing indentation before the closing brace remains outside the edit.
        if (position !== lineStart) added += closeIndent;
        if (tree.properties.length && !tree.trailing) {
            if (tree.lastEnd === position) added = ',' + added;
            else edits.push({ start: tree.lastEnd, end: tree.lastEnd, text: ',' });
        }
        edits.push({ start: position, end: position, text: added });
    }
    edits.sort(function (a, b) { return b.start - a.start || b.end - a.end; });
    let output = text;
    edits.forEach(function (edit) { output = output.slice(0, edit.start) + edit.text + output.slice(edit.end); });
    parseDocument(output);
    return output;
}

function currentUid() { return typeof process.getuid === 'function' ? process.getuid() : null; }
function owned(stat) { return currentUid() === null || stat.uid === currentUid(); }
function statOrNull(file) {
    try { return fs.lstatSync(file); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
function safeDirectory(directory, create) {
    if (!path.isAbsolute(directory)) fail('unsafe_path');
    const resolved = path.resolve(directory), base = path.parse(resolved).root;
    let part = base;
    for (const segment of resolved.slice(base.length).split(path.sep).filter(Boolean)) {
        part = path.join(part, segment);
        let stat = statOrNull(part);
        if (!stat && create) { fs.mkdirSync(part, { mode: 0o700 }); stat = fs.lstatSync(part); }
        if (!stat || stat.isSymbolicLink() || !stat.isDirectory()) fail('unsafe_path');
    }
    const final = fs.lstatSync(resolved);
    if (!owned(final)) fail('unsafe_path');
    return resolved;
}
function readSettings(file) {
    const stat = statOrNull(file);
    if (!stat) return { bytes: null, stat: null };
    if (stat.isSymbolicLink() || !stat.isFile() || stat.nlink !== 1 || !owned(stat)) fail('unsafe_path');
    if (stat.size > MAX_BYTES) fail('settings_too_large');
    const descriptor = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
    let bytes, opened;
    try {
        opened = fs.fstatSync(descriptor);
        const buffer = Buffer.alloc(MAX_BYTES + 1);
        let offset = 0, count;
        while (offset < buffer.length && (count = fs.readSync(descriptor, buffer, offset, buffer.length - offset, null)) > 0) offset += count;
        bytes = buffer.slice(0, offset);
    }
    finally { fs.closeSync(descriptor); }
    if (opened.ino !== stat.ino || opened.dev !== stat.dev || bytes.length > MAX_BYTES) fail('concurrent_change');
    if (!Buffer.from(bytes.toString('utf8'), 'utf8').equals(bytes)) fail('malformed_settings');
    return { bytes: bytes, stat: stat };
}
function sameSnapshot(file, snapshot) {
    const now = readSettings(file);
    if (snapshot.bytes === null) return now.bytes === null;
    if (!now.bytes) return false;
    return now.stat.ino === snapshot.stat.ino && now.stat.dev === snapshot.stat.dev && now.stat.mtimeMs === snapshot.stat.mtimeMs && now.stat.ctimeMs === snapshot.stat.ctimeMs && now.bytes.equals(snapshot.bytes);
}
function writeExclusive(file, bytes, mode) {
    const descriptor = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, mode);
    try { fs.writeFileSync(descriptor, bytes); fs.fsyncSync(descriptor); }
    finally { fs.closeSync(descriptor); }
}
function unlinkOwned(file) {
    const stat = statOrNull(file);
    if (stat && !stat.isSymbolicLink() && stat.isFile() && owned(stat)) fs.unlinkSync(file);
}
function acquireLock(file) {
    try { writeExclusive(file, Buffer.from(JSON.stringify({ pid: process.pid })), 0o600); return; }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
    const stat = statOrNull(file);
    if (!stat || !stat.isFile() || stat.isSymbolicLink() || !owned(stat) || stat.nlink !== 1 || stat.size > 1024) fail('concurrent_change');
    let pid;
    try { pid = JSON.parse(fs.readFileSync(file, 'utf8')).pid; } catch (_) { fail('concurrent_change'); }
    if (!Number.isInteger(pid) || pid < 1 || Date.now() - stat.mtimeMs < 30000) fail('concurrent_change');
    try { process.kill(pid, 0); fail('concurrent_change'); }
    catch (error) { if (error.code !== 'ESRCH') fail('concurrent_change'); }
    const now = fs.lstatSync(file);
    if (now.ino !== stat.ino || now.dev !== stat.dev || now.mtimeMs !== stat.mtimeMs) fail('concurrent_change');
    fs.unlinkSync(file);
    try { writeExclusive(file, Buffer.from(JSON.stringify({ pid: process.pid })), 0o600); }
    catch (error) { if (error.code === 'EEXIST') fail('concurrent_change'); throw error; }
}

function configureDirectories(directories, port) {
    port = portValue(port);
    if (!directories.length || directories.length > 16) fail('vscode_not_found');
    const records = [], locks = [], token = new Date().toISOString().replace(/[^0-9]/g, '') + '-' + crypto.randomBytes(6).toString('hex');
    let committed = 0;
    try {
        // Stage every target before committing any. A malformed second VS Code
        // installation must not leave the first installation partly configured.
        for (const directory of Array.from(new Set(directories.map(function (item) { return path.resolve(item); }))).sort()) {
            safeDirectory(directory, true);
            const file = path.join(directory, 'settings.json'), lock = path.join(directory, '.codex-tunnel-vscode.lock');
            acquireLock(lock); locks.push(lock);
            const original = readSettings(file), text = original.bytes === null ? '{\n}\n' : original.bytes.toString('utf8');
            const bytes = Buffer.from(patchSettings(text, port), 'utf8');
            const record = { file: file, directory: directory, original: original, bytes: bytes, changed: !original.bytes || !bytes.equals(original.bytes), committed: false, temporary: null };
            records.push(record);
            if (record.changed) {
                if (original.bytes) writeExclusive(path.join(directory, 'settings.json.codex-tunnel-backup-' + token), original.bytes, 0o600);
                record.temporary = path.join(directory, '.codex-tunnel-vscode-' + token + '.tmp');
                writeExclusive(record.temporary, bytes, original.stat ? original.stat.mode & 0o777 : 0o600);
            }
        }
        for (const record of records) {
            if (!record.changed) continue;
            safeDirectory(record.directory, false);
            if (!sameSnapshot(record.file, record.original)) fail('concurrent_change');
            fs.renameSync(record.temporary, record.file);
            record.temporary = null; record.committed = true; committed++;
        }
        return { changed: committed > 0 ? 1 : 0, targets: records.length };
    } catch (error) {
        let rollbackFailed = false;
        for (const record of records.slice().reverse()) {
            if (!record.committed) continue;
            try {
                safeDirectory(record.directory, false);
                const now = readSettings(record.file);
                if (!now.bytes || !now.bytes.equals(record.bytes)) { rollbackFailed = true; continue; }
                if (record.original.bytes === null) fs.unlinkSync(record.file);
                else {
                    const rollback = path.join(record.directory, '.codex-tunnel-vscode-' + token + '.rollback');
                    writeExclusive(rollback, record.original.bytes, record.original.stat.mode & 0o777);
                    try { fs.renameSync(rollback, record.file); } finally { unlinkOwned(rollback); }
                }
            } catch (_) { rollbackFailed = true; }
        }
        if (rollbackFailed) fail('partial_write');
        throw error;
    } finally {
        records.forEach(function (record) { if (record.temporary) { try { unlinkOwned(record.temporary); } catch (_) {} } });
        locks.forEach(function (lock) { try { unlinkOwned(lock); } catch (_) {} });
    }
}

function discoverDirectories(home, environment, procRoot) {
    home = fs.realpathSync(home);
    const roots = new Set(), data = new Set(), overriddenRoots = new Set();
    function addRoot(root) {
        if (!root || !path.isAbsolute(root)) return;
        const stat = statOrNull(root);
        if (stat) { safeDirectory(root, false); roots.add(path.resolve(root)); }
    }
    addRoot(path.join(home, '.vscode-server'));
    addRoot(path.join(home, '.vscode-server-insiders'));
    if (environment.VSCODE_AGENT_FOLDER) addRoot(environment.VSCODE_AGENT_FOLDER);
    if (procRoot && statOrNull(procRoot)) {
        const processes = fs.readdirSync(procRoot).filter(function (name) { return /^[0-9]+$/.test(name); }).slice(0, 4096);
        for (const pid of processes) {
            const base = path.join(procRoot, pid);
            let arguments_, owner;
            try {
                owner = fs.statSync(base); if (!owned(owner)) continue;
                const cmd = fs.readFileSync(path.join(base, 'cmdline'));
                if (cmd.length > 65536) continue;
                arguments_ = cmd.toString('utf8').split('\0').filter(Boolean);
            } catch (_) { continue; }
            // Inspect server processes only; never run arguments from /proc.
            const main = arguments_.find(function (argument) { return /(?:^|\/)out\/server-main\.js$/.test(argument); });
            if (!main) continue;
            let serverData, userData;
            arguments_.forEach(function (argument, index) {
                if (argument === '--server-data-dir') serverData = arguments_[index + 1];
                if (argument.indexOf('--server-data-dir=') === 0) serverData = argument.slice(18);
                if (argument === '--user-data-dir') userData = arguments_[index + 1];
                if (argument.indexOf('--user-data-dir=') === 0) userData = argument.slice(16);
            });
            const match = /^(.*)\/(?:cli\/servers\/[^/]+\/server|bin\/[^/]+)\/out\/server-main\.js$/.exec(main);
            const installationRoot = match ? path.resolve(match[1]) : null;
            if ((serverData && !path.isAbsolute(serverData)) || (userData && !path.isAbsolute(userData))) fail('discovery_failed');
            // VS Code server.main.ts: remoteData=--server-data-dir or agent
            // folder; userData=--user-data-dir or <remoteData>/data. The machine
            // settings live at <userData>/Machine, not remoteData/Machine.
            if (userData) {
                safeDirectory(userData, false); data.add(path.resolve(userData));
                if (installationRoot) overriddenRoots.add(installationRoot);
                if (serverData) overriddenRoots.add(path.resolve(serverData));
            } else if (serverData) {
                addRoot(serverData);
                if (installationRoot && installationRoot !== path.resolve(serverData)) overriddenRoots.add(installationRoot);
            } else if (match) addRoot(match[1]);
        }
    }
    roots.forEach(function (root) { if (!overriddenRoots.has(root)) data.add(path.join(root, 'data')); });
    return Array.from(data).map(function (directory) { return path.join(directory, 'Machine'); });
}

function main() {
    const allowed = new Set(['invalid_port', 'runtime_missing', 'vscode_not_found', 'malformed_settings', 'unsafe_path', 'settings_too_large', 'concurrent_change', 'write_failed', 'unsupported_runtime', 'discovery_failed', 'partial_write']);
    try {
        if (process.argv.length !== 3) fail('invalid_port');
        const port = portValue(process.argv[2]);
        const directories = discoverDirectories(os.homedir(), process.env, process.platform === 'linux' ? '/proc' : null);
        const result = configureDirectories(directories, port);
        process.stdout.write('VSCODE_CONFIGURED changed=' + result.changed + ' targets=' + result.targets + '\n');
    } catch (error) {
        const code = allowed.has(error.code) ? error.code : 'write_failed';
        process.stdout.write('VSCODE_ERROR code=' + code + '\n');
        process.exitCode = 1;
    }
}

module.exports = { patchSettings: patchSettings, parseDocument: parseDocument, configureDirectories: configureDirectories, discoverDirectories: discoverDirectories };
if (require.main === module || process.argv[1] === '-') main();
