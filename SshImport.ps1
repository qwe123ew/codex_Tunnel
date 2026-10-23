# PowerShell 5.1. Read-only importer: no login, key reads, or config writes.
# Caller dot-sources ProxyTools.ps1 and TunnelTools.ps1 first.

function Split-SshImportTokens {
    param([string]$Text)
    $tokens = New-Object 'System.Collections.Generic.List[string]'
    $token = New-Object Text.StringBuilder
    $quote = [char]0
    $started = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -eq [char]0) { throw 'SSH config contains unsupported control characters; use manual setup.' }
        if ($c -eq '\') {
            # Relevant directives with escapes have platform-dependent parsing.
            # Fail closed rather than scan a different Include graph from ssh.
            throw 'Escaped SSH config tokens are unsupported for automatic import; use forward-slash paths or manual setup.'
        }
        if ($quote -ne [char]0) {
            if ($c -eq $quote) { $quote = [char]0 } else { [void]$token.Append($c) }
            $started = $true
        } elseif ($c -eq '"' -or $c -eq "'") {
            $quote = $c
            $started = $true
        } elseif ([char]::IsWhiteSpace($c)) {
            if ($started) { $tokens.Add($token.ToString()); [void]$token.Clear(); $started = $false }
        } elseif ($c -eq '#') {
            if ($started) { throw 'Ambiguous inline SSH comment syntax; add whitespace before the comment or use manual setup.' }
            break
        } else {
            [void]$token.Append($c)
            $started = $true
        }
    }
    if ($quote -ne [char]0) { throw 'SSH config has an unterminated quoted token; use manual setup.' }
    if ($started) { $tokens.Add($token.ToString()) }
    return $tokens.ToArray()
}

function Get-SshImportHome {
    $userDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($userDirectory)) { throw 'Cannot resolve the current user SSH directory; use manual setup.' }
    return $userDirectory
}

function Resolve-SshImportIncludes {
    param([string]$Pattern)
    # OpenSSH user Include paths are relative to ~/.ssh, including with -F.
    # Only * and ? globs are accepted. Refuse other expansions before ssh runs.
    if ($Pattern -match '[\x00-\x1f\[\]%$`]' -or $Pattern.Contains('\')) {
        throw 'Unsupported Include path or expansion; use forward-slash paths and simple * or ? globs, or manual setup.'
    }
    $userDirectory = Get-SshImportHome
    if ($Pattern -eq '~') { $Pattern = $userDirectory }
    elseif ($Pattern.StartsWith('~/')) { $Pattern = Join-Path $userDirectory $Pattern.Substring(2) }
    elseif ($Pattern.StartsWith('~')) { throw 'Include paths for another user are unsupported; use manual setup.' }
    if (-not [IO.Path]::IsPathRooted($Pattern)) { $Pattern = Join-Path (Join-Path $userDirectory '.ssh') $Pattern }
    if ($Pattern.StartsWith('\\') -or $Pattern.StartsWith('//')) { throw 'Network Include paths are unsupported for automatic import; use manual setup.' }
    try {
        $fullPattern = $Pattern
        if ($Pattern -notmatch '[*?]') {
            $fullPattern = [IO.Path]::GetFullPath($Pattern)
            if (Test-Path -LiteralPath $fullPattern -PathType Leaf) { return $fullPattern }
            return
        }
        # Get-ChildItem uses compatible * and ? matching for this restricted
        # subset. Do not silently suppress access errors in a matched Include.
        $items = @(Get-ChildItem -Path $fullPattern -File -Force -ErrorAction Stop | Sort-Object FullName)
        foreach ($item in $items) { $item.FullName }
    } catch [System.Management.Automation.ItemNotFoundException] {
        # OpenSSH permits an Include glob with no matches.
        return
    } catch {
        throw 'An SSH Include path could not be safely inspected; use manual setup.'
    }
}

function Read-SshImportGraph {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    try { $resolved = [IO.Path]::GetFullPath($ConfigPath) } catch { throw 'Invalid SSH config path.' }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw 'SSH config file was not found. Select another config path or use manual setup.' }
    if ($resolved.StartsWith('\\')) { throw 'Network SSH config paths are unsupported; use a local config or manual setup.' }
    $state = @{
        Visited = @{}; Stack = @{}; Aliases = (New-Object 'System.Collections.Generic.List[object]')
        AliasNames = @{}; Count = 0
    }
    function Visit-SshImportFile {
        param([string]$Path, [int]$Depth, $State)
        if ($Depth -gt 64) { throw 'SSH Include recursion exceeds the 64-level limit; use manual setup.' }
        $fullPath = [IO.Path]::GetFullPath($Path)
        if ($State.Stack.ContainsKey($fullPath)) { throw 'SSH Include cycle detected; use manual setup.' }
        if ($State.Visited.ContainsKey($fullPath)) { return }
        $State.Count++
        if ($State.Count -gt 64) { throw 'SSH Include graph exceeds the 64-file limit; use manual setup.' }
        $State.Stack[$fullPath] = $true
        try {
            try {
                $fileInfo = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
                if ($fileInfo.Length -gt 1MB) { throw 'oversize' }
                $content = [IO.File]::ReadAllText($fullPath)
            } catch { throw 'An SSH config file cannot be read safely (missing, inaccessible, or over 1 MiB); use manual setup.' }
            if ($content.IndexOf([char]0) -ge 0) { throw 'SSH config contains unsupported control characters; use manual setup.' }
            foreach ($line in ($content -split "`n")) {
                $clean = $line.Trim()
                if (-not $clean -or $clean.StartsWith('#')) { continue }
                if ($clean -notmatch '\A(?<directive>[A-Za-z][A-Za-z0-9]*)(?:\s+|\s*=\s*|$)(?<rest>.*)\z') {
                    throw 'Unsupported SSH config directive syntax; use manual setup.'
                }
                $directive = $Matches['directive'].ToLowerInvariant()
                $rest = $Matches['rest']
                if ($rest.StartsWith('=')) { $rest = $rest.Substring(1).TrimStart() }
                # Inspect only structural directives; never echo command text.
                if ($directive -notin @('host', 'include', 'match')) { continue }
                $tokens = @(Split-SshImportTokens $rest)
                if ($directive -eq 'match') {
                    foreach ($item in $tokens) {
                        if ($item.TrimStart('!') -match '(?i)\Aexec(?:=|$)') {
                            throw 'Match exec can execute a local command during ssh -G. Automatic import is disabled; use manual setup.'
                        }
                    }
                } elseif ($directive -eq 'include') {
                    foreach ($pattern in $tokens) {
                        foreach ($included in @(Resolve-SshImportIncludes $pattern)) {
                            Visit-SshImportFile $included ($Depth + 1) $State
                        }
                    }
                } else {
                    foreach ($name in $tokens) {
                        if ($name -notmatch '\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}\z') { continue }
                        if ($State.AliasNames.ContainsKey($name)) { continue }
                        $State.AliasNames[$name] = $true
                        $State.Aliases.Add([pscustomobject]@{ Alias = $name; SourceFile = $fullPath })
                    }
                }
            }
            $State.Visited[$fullPath] = $true
        } finally { [void]$State.Stack.Remove($fullPath) }
    }
    Visit-SshImportFile $resolved 1 $state
    return [pscustomobject]@{ ConfigPath = $resolved; Aliases = $state.Aliases.ToArray() }
}

function Get-SshConfigAliases {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    $graph = Read-SshImportGraph $ConfigPath
    return $graph.Aliases
}

function Get-SshImportUnsupportedFields {
    # Compare against this ssh.exe's empty-config defaults, not guessed values.
    # These cannot be represented by the intentionally small launcher profile.
    return @('identitiesonly', 'identityagent', 'certificatefile', 'pkcs11provider',
        'securitykeyprovider', 'hostkeyalias', 'userknownhostsfile', 'globalknownhostsfile',
        'bindaddress', 'bindinterface', 'preferredauthentications', 'passwordauthentication',
        'pubkeyauthentication', 'kbdinteractiveauthentication', 'gssapiauthentication',
        'hostbasedauthentication', 'stricthostkeychecking', 'verifyhostkeydns', 'checkhostip',
        'hostkeyalgorithms', 'pubkeyacceptedalgorithms', 'ciphers', 'macs', 'kexalgorithms',
        'proxyusefdpass', 'revokedhostkeys', 'knownhostscommand')
}

function ConvertFrom-SshImportOutput {
    param([string]$OutputText)
    $retained = @('hostname', 'user', 'port', 'proxyjump', 'proxycommand') + @(Get-SshImportUnsupportedFields)
    $fields = @{}
    $identities = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($OutputText -split '\r?\n')) {
        if ($line -notmatch '\A(?<name>[a-z0-9]+)\s+(?<value>.*)\z') { continue }
        $name = $Matches['name']
        $value = $Matches['value']
        if ($name -eq 'identityfile') { $identities.Add($value) }
        elseif ($name -in $retained) { $fields[$name] = $value }
    }
    return [pscustomobject]@{ Fields = $fields; Identities = $identities.ToArray() }
}

function Get-SshImportDefaults {
    param([string]$SshPath)
    # -F NUL prevents user and system configs from being evaluated here.
    $probe = Invoke-ProxyProcess -FileName $SshPath -Arguments @('-G', '-F', 'NUL', '--', 'localhost') -TimeoutSeconds 10
    if ($probe.ExitCode -ne 0 -or $probe.TimedOut) { throw 'Cannot inspect SSH defaults safely; use manual setup.' }
    return ConvertFrom-SshImportOutput $probe.Output
}

function Get-SshImportEffective {
    param([string]$Alias, [string]$ConfigPath, [string]$SshPath, [string]$UserOverride = '', [string]$PortOverride = '', $Defaults)
    # Recheck the entire graph before every invocation, including jump aliases.
    $graph = Read-SshImportGraph $ConfigPath
    $arguments = @('-G', '-F', $graph.ConfigPath)
    if ($UserOverride) { $arguments += @('-l', $UserOverride) }
    if ($PortOverride) { $arguments += @('-p', $PortOverride) }
    $arguments += @('--', $Alias)
    $probe = Invoke-ProxyProcess -FileName $SshPath -Arguments $arguments -TimeoutSeconds 10
    if ($probe.TimedOut) { throw 'SSH config evaluation timed out; use manual setup.' }
    if ($probe.ExitCode -ne 0) { throw 'SSH could not evaluate this config. Check it locally or use manual setup; command output is not displayed.' }
    $effective = ConvertFrom-SshImportOutput $probe.Output
    $fields = $effective.Fields
    if ($fields.ContainsKey('proxycommand') -and $fields.proxycommand -ne 'none') {
        throw 'ProxyCommand cannot be represented by this launcher. Use manual setup with explicit jump hosts.'
    }
    foreach ($setting in @(Get-SshImportUnsupportedFields)) {
        if ([string]$fields[$setting] -cne [string]$Defaults.Fields[$setting]) {
            # Only a hard-coded directive name is surfaced, never its value.
            throw "Unsupported nondefault SSH setting '$setting' cannot be preserved. Use manual setup after checking authentication, routing, and host-key requirements."
        }
    }
    foreach ($required in @('hostname', 'user', 'port')) {
        if (-not $fields.ContainsKey($required)) { throw 'SSH returned incomplete endpoint settings; use manual setup.' }
    }
    return $effective
}

function Resolve-SshImportIdentity {
    param([string[]]$Identities, $Fields, [string]$Alias, [string[]]$DefaultIdentities = @())
    if ($Identities -contains 'none') {
        if (@($Identities | Where-Object { $_ -ne 'none' }).Count -gt 0) {
            throw 'IdentityFile none mixed with other keys requires manual setup.'
        }
        return 'none'
    }
    $found = @{}
    $userDirectory = Get-SshImportHome
    # A basename alone cannot distinguish an explicit missing id_rsa from
    # OpenSSH's implicit default list. Compare the complete installed default list.
    $implicitDefaults = $DefaultIdentities.Count -gt 0 -and (($Identities -join "`0") -ceq ($DefaultIdentities -join "`0"))
    foreach ($identity in $Identities) {
        if ($identity -eq 'none') { continue }
        $path = $identity
        if ($path.StartsWith('"') -and $path.EndsWith('"')) { $path = $path.Substring(1, $path.Length - 2) }
        if ($path -match '\$|[\x00-\x1f"]') { throw 'IdentityFile has unsupported path expansion; choose the key manually.' }
        $expanded = New-Object Text.StringBuilder
        for ($i = 0; $i -lt $path.Length; $i++) {
            if ($path[$i] -ne '%') { [void]$expanded.Append($path[$i]); continue }
            $i++
            if ($i -ge $path.Length) { throw 'IdentityFile has an incomplete token; choose the key manually.' }
            $replacement = switch -CaseSensitive ($path[$i]) {
                'd' { $userDirectory }
                'h' { $Fields.hostname }
                'r' { $Fields.user }
                'p' { $Fields.port }
                'n' { $Alias }
                'u' { [Environment]::UserName }
                '%' { '%' }
                default { throw 'IdentityFile uses an unsupported token; choose the key manually.' }
            }
            [void]$expanded.Append($replacement)
        }
        $path = $expanded.ToString()
        if ($path -eq '~') { $path = $userDirectory }
        elseif ($path -match '\A~[/\\]') { $path = Join-Path $userDirectory $path.Substring(2) }
        elseif ($path.StartsWith('~')) { throw 'IdentityFile for another user is unsupported; choose the key manually.' }
        if (-not [IO.Path]::IsPathRooted($path)) { throw 'Relative IdentityFile paths depend on the SSH working directory; choose an absolute key path manually.' }
        if ($path.StartsWith('\\') -or $path.StartsWith('//')) { throw 'Network IdentityFile paths require manual setup.' }
        if ($path.Contains('%')) { throw 'Literal percent signs in IdentityFile cannot be represented safely; choose the key manually.' }
        try { $fullPath = [IO.Path]::GetFullPath($path) } catch { throw 'Invalid IdentityFile path; choose the key manually.' }
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) { $found[$fullPath] = $true }
        elseif (-not $implicitDefaults) { throw 'An explicit IdentityFile is missing; correct the path or choose a key manually.' }
    }
    if ($found.Count -gt 1) { throw 'Multiple existing identity files make authentication ambiguous. Choose one key with manual setup.' }
    if ($found.Count -eq 1) { return [string]@($found.Keys)[0] }
    return ''
}

function ConvertTo-SshImportEndpoint {
    param($Effective, [string]$Alias, $Defaults)
    $endpoint = [pscustomobject]@{
        host = [string]$Effective.Fields.hostname
        user = [string]$Effective.Fields.user
        port = [string]$Effective.Fields.port
        identityFile = Resolve-SshImportIdentity $Effective.Identities $Effective.Fields $Alias $Defaults.Identities
    }
    Assert-SshEndpoint $endpoint 'Imported endpoint'
    $endpoint.port = [int]$endpoint.port
    return $endpoint
}

function Import-SshHostProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Alias,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$SshPath
    )
    if ($Alias -notmatch '\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}\z') { throw 'Choose a literal SSH host alias without spaces or options.' }
    # Preflight happens before even the safe empty-config defaults invocation.
    [void](Read-SshImportGraph $ConfigPath)
    $defaults = Get-SshImportDefaults $SshPath
    $effective = Get-SshImportEffective $Alias $ConfigPath $SshPath -Defaults $defaults
    $server = ConvertTo-SshImportEndpoint $effective $Alias $defaults
    $jumps = New-Object 'System.Collections.Generic.List[object]'
    $jumpText = [string]$effective.Fields['proxyjump']
    if ($jumpText -and $jumpText -ne 'none') {
        $jumpSpecs = @($jumpText -split ',')
        if ($jumpSpecs.Count -gt 4) { throw 'At most four ProxyJump hosts are supported; use manual setup.' }
        foreach ($spec in $jumpSpecs) {
            if ($spec -notmatch '\A(?:(?<user>[A-Za-z0-9_][A-Za-z0-9_.-]{0,63})@)?(?:\[(?<ipv6>[0-9A-Fa-f:]+)\]|(?<alias>[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}))(?::(?<port>[0-9]{1,5}))?\z') {
                throw 'Unsupported ProxyJump endpoint syntax; use manual setup.'
            }
            $jumpAlias = $Matches['alias']
            if ($Matches['ipv6']) { $jumpAlias = $Matches['ipv6'] }
            $jumpUser = [string]$Matches['user']
            $jumpPort = [string]$Matches['port']
            if ($jumpPort) { Assert-PortNumber $jumpPort 1 'ProxyJump port' }
            $jumpEffective = Get-SshImportEffective $jumpAlias $ConfigPath $SshPath $jumpUser $jumpPort $defaults
            $nested = [string]$jumpEffective.Fields['proxyjump']
            if ($nested -and $nested -ne 'none') { throw 'A jump host has a nested ProxyJump rule. Use manual setup to specify the complete ordered chain.' }
            $jumps.Add((ConvertTo-SshImportEndpoint $jumpEffective $jumpAlias $defaults))
        }
    }
    $profile = [pscustomobject]@{
        version = 1; server = $server; jumpHosts = @($jumps.ToArray())
        remotePort = 11082; checkIntervalSeconds = 60
    }
    Assert-TunnelProfile $profile
    return $profile
}

# Native GUI connections retain SSH's own authentication and routing semantics.
# The older import functions above deliberately remain strict for portable
# manual profiles. These helpers never reduce a native config to one key/hop.
function Assert-NativeSshLocalPath {
    param([string]$Path, [string]$Label = 'SSH config')
    # Reject UNC/device paths before GetFullPath, File.Exists or other I/O.
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\x00-\x1f]' -or
        $Path.StartsWith('\\') -or $Path.StartsWith('//')) {
        throw "Network or invalid $Label paths are unsupported; select a local file."
    }
    try { $fullPath = [IO.Path]::GetFullPath($Path) } catch { throw "Invalid $Label path." }
    if ($fullPath.StartsWith('\\') -or $fullPath.StartsWith('//')) { throw "Network $Label paths are unsupported; select a local file." }
    return $fullPath
}

function Assert-NativeSshAlias {
    param([string]$Alias)
    if ($Alias -notmatch '\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}\z') {
        throw 'Choose a literal SSH host alias without spaces or options.'
    }
}

function Read-NativeSshGraph {
    param([string]$ConfigPath)
    $resolved = Assert-NativeSshLocalPath $ConfigPath
    $state = @{
        Files = (New-Object 'System.Collections.Generic.List[object]')
        ByPath = @{}; Stack = @{}; TotalBytes = 0
    }
    function Visit-NativeSshFile {
        param([string]$Path, [int]$Depth, $State)
        $fullPath = Assert-NativeSshLocalPath $Path
        if ($Depth -gt 64) { throw 'SSH Include recursion exceeds the 64-level limit; use manual setup.' }
        if ($State.Stack.ContainsKey($fullPath)) { throw 'SSH Include cycle detected; use manual setup.' }
        if ($State.ByPath.ContainsKey($fullPath)) { return $State.ByPath[$fullPath] }
        if ($State.Files.Count -ge 64) { throw 'SSH Include graph exceeds the 64-file limit; use manual setup.' }
        try {
            $info = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            if ($info.PSIsContainer -or $info.Length -gt 1MB) { throw 'oversize' }
            $State.TotalBytes += $info.Length
            if ($State.TotalBytes -gt 8MB) { throw 'oversize' }
            $content = [IO.File]::ReadAllText($fullPath)
        } catch { throw 'An SSH config file cannot be read safely (missing, inaccessible, or over 1 MiB); use manual setup.' }
        if ($content.IndexOf([char]0) -ge 0) { throw 'SSH config contains unsupported control characters; use manual setup.' }
        $entry = [pscustomobject]@{ Path = $fullPath; Number = $State.Files.Count; Lines = (New-Object 'System.Collections.Generic.List[object]') }
        $State.ByPath[$fullPath] = $entry
        $State.Files.Add($entry)
        $State.Stack[$fullPath] = $true
        try {
            foreach ($line in ($content -split '\r?\n')) {
                $clean = $line.Trim()
                if (-not $clean -or $clean.StartsWith('#')) {
                    $entry.Lines.Add([pscustomobject]@{ Text = $line; Directive = ''; Includes = @() })
                    continue
                }
                if ($clean -notmatch '\A(?<directive>[A-Za-z][A-Za-z0-9]*)(?:\s+|\s*=\s*|$)(?<rest>.*)\z') {
                    throw 'Unsupported SSH config directive syntax; use manual setup.'
                }
                $directive = $Matches['directive'].ToLowerInvariant()
                $rest = $Matches['rest']
                if ($rest.StartsWith('=')) { $rest = $rest.Substring(1).TrimStart() }
                $included = New-Object 'System.Collections.Generic.List[object]'
                if ($directive -eq 'match') {
                    # Match exec is the one structural directive that ssh -G
                    # can execute locally. Reject before any SSH invocation.
                    if ($rest -match '(?i)(?:^|\s)!?exec(?:\s|=|$)') {
                        throw 'Match exec can execute a local command during ssh -G. Automatic import is disabled; use manual setup.'
                    }
                    $tokens = @(Split-SshImportTokens $rest)
                    foreach ($item in $tokens) {
                        if ($item.TrimStart('!') -match '(?i)\Aexec(?:=|$)') {
                            throw 'Match exec can execute a local command during ssh -G. Automatic import is disabled; use manual setup.'
                        }
                    }
                } elseif ($directive -eq 'include') {
                    # Windows paths in Include are accepted and normalized only
                    # for lookup; snapshot Includes are fully rewritten below.
                    # Other directive values (keys, commands, tokens) stay raw.
                    $tokens = @(Split-SshImportTokens ($rest.Replace('\', '/')))
                    foreach ($pattern in $tokens) {
                        if ($pattern.StartsWith('//')) { throw 'Network Include paths are unsupported for automatic import; use a local config.' }
                        foreach ($child in @(Resolve-SshImportIncludes $pattern)) {
                            $included.Add((Visit-NativeSshFile $child ($Depth + 1) $State))
                        }
                    }
                }
                $entry.Lines.Add([pscustomobject]@{ Text = $line; Directive = $directive; Includes = $included.ToArray() })
            }
        } finally { [void]$State.Stack.Remove($fullPath) }
        return $entry
    }
    $rootEntry = Visit-NativeSshFile $resolved 1 $state
    return [pscustomobject]@{ Root = $rootEntry; Files = $state.Files.ToArray() }
}

function New-NativeTunnelConfig {
    param([string]$ConfigPath, [string]$DestinationDirectory)
    # Read and preflight the complete graph before writing any snapshot files.
    # ssh only sees these captured bytes, so source changes cannot bypass the
    # Match exec check between preflight and the native config evaluation.
    $graph = Read-NativeSshGraph $ConfigPath
    $destination = Assert-NativeSshLocalPath $DestinationDirectory 'snapshot directory'
    [void][IO.Directory]::CreateDirectory($destination)
    $paths = @{}
    foreach ($entry in $graph.Files) {
        $path = Join-Path $destination ('config-{0:D3}.conf' -f $entry.Number)
        if (Test-Path -LiteralPath $path) { throw 'SSH snapshot destination already exists; retry with a new session.' }
        $paths[$entry.Path] = $path
    }
    $strip = @('localforward', 'remoteforward', 'dynamicforward', 'remotecommand',
        'localcommand', 'permitlocalcommand', 'requesttty', 'sessiontype', 'stdinnull',
        'forkafterauthentication', 'controlmaster', 'controlpath', 'controlpersist',
        'clearallforwardings', 'exitonforwardfailure', 'tunnel', 'tunneldevice')
    $written = New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach ($entry in $graph.Files) {
            $lines = New-Object 'System.Collections.Generic.List[string]'
            foreach ($line in $entry.Lines) {
                if ($line.Directive -in $strip) { continue }
                if ($line.Directive -eq 'include') {
                    # One Include per matched file preserves occurrence order
                    # and conditional Host/Match state across file boundaries.
                    foreach ($child in $line.Includes) {
                        $lines.Add('Include "' + ([string]$paths[$child.Path]).Replace('\', '/') + '"')
                    }
                } else { $lines.Add([string]$line.Text) }
            }
            $path = [string]$paths[$entry.Path]
            [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
            $written.Add($path)
            # Windows OpenSSH checks Include ACLs. Only these new app-owned
            # files are restricted; original user config permissions stay intact.
            $acl = New-Object Security.AccessControl.FileSecurity
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl.SetOwner($sid); $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
            Set-Acl -LiteralPath $path -AclObject $acl
        }
        return [pscustomobject]@{ RootPath = [string]$paths[$graph.Root.Path]; Files = $written.ToArray() }
    } catch {
        foreach ($path in $written) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Get-NativeSshConfigAliases {
    param([string]$ConfigPath)
    $graph = Read-NativeSshGraph $ConfigPath
    $state = @{ Files = @{}; Aliases = @{}; Results = (New-Object 'System.Collections.Generic.List[object]') }
    function Visit-NativeSshAliases {
        param($Entry, $State)
        if ($State.Files.ContainsKey($Entry.Path)) { return }
        $State.Files[$Entry.Path] = $true
        foreach ($line in $Entry.Lines) {
            if ($line.Directive -eq 'include') {
                foreach ($child in $line.Includes) { Visit-NativeSshAliases $child $State }
            } elseif ($line.Directive -eq 'host') {
                $rest = [regex]::Replace($line.Text.Trim(), '(?i)\Ahost(?:\s+|\s*=\s*|$)', '')
                if ($rest.StartsWith('=')) { $rest = $rest.Substring(1).TrimStart() }
                foreach ($alias in @(Split-SshImportTokens $rest)) {
                    if ($alias -notmatch '\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}\z' -or $State.Aliases.ContainsKey($alias)) { continue }
                    $State.Aliases[$alias] = $true
                    $State.Results.Add([pscustomobject]@{ Alias = $alias; SourceFile = $Entry.Path })
                }
            }
        }
    }
    Visit-NativeSshAliases $graph.Root $state
    return $state.Results.ToArray()
}

function Get-NativeSshCandidates {
    param([string]$SshPath = '')
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if ($SshPath) {
        $path = Assert-NativeSshLocalPath $SshPath 'SSH executable'
        if ([IO.Path]::GetExtension($path) -ine '.exe' -or -not [IO.File]::Exists($path)) {
            throw 'Configured SSH executable is missing. Check the VS Code remote.SSH.path setting.'
        }
        $candidates.Add($path)
    } else {
        $possible = @((Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'))
        $commands = @(Get-Command 'ssh.exe' -CommandType Application -All -ErrorAction SilentlyContinue)
        foreach ($command in $commands) { $possible += $command.Source }
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if ($base) { $possible += (Join-Path $base 'Git\usr\bin\ssh.exe') }
        }
        if ($env:LOCALAPPDATA) { $possible += (Join-Path $env:LOCALAPPDATA 'Programs\Git\usr\bin\ssh.exe') }
        $seen = @{}
        foreach ($candidate in $possible) {
            try { $path = Assert-NativeSshLocalPath ([string]$candidate) 'SSH executable' } catch { continue }
            if (-not $seen.ContainsKey($path) -and [IO.File]::Exists($path)) {
                $seen[$path] = $true; $candidates.Add($path)
            }
        }
    }
    if ($candidates.Count -eq 0) { throw 'ssh.exe is missing. Install/enable Windows OpenSSH Client or curl; this launcher does not download software automatically.' }
    return $candidates.ToArray()
}

function Get-NativeSshProfile {
    param([string]$Alias, [string]$ConfigPath, [string]$SshPath = '', [string]$PreviewDirectory = '')
    Assert-NativeSshAlias $Alias
    $source = Assert-NativeSshLocalPath $ConfigPath
    $candidates = @(Get-NativeSshCandidates $SshPath)
    # GUI callers supply an owned directory so killing a helper cannot leave
    # authentication/routing config snapshots behind. Standalone calls own a
    # unique temporary directory and remove it in this function's finally.
    $directory = if ($PreviewDirectory) { Assert-NativeSshLocalPath $PreviewDirectory 'preview directory' } else {
        Join-Path ([IO.Path]::GetTempPath()) ('CodexNativePreview-' + [guid]::NewGuid().ToString('N'))
    }
    $snapshot = $null
    try {
        $snapshot = New-NativeTunnelConfig $source $directory
        $effective = $null
        $selected = ''
        $timedOut = $false
        $watch = [Diagnostics.Stopwatch]::StartNew()
        foreach ($candidate in $candidates) {
            $remaining = [int][Math]::Floor(20 - $watch.Elapsed.TotalSeconds)
            if ($remaining -lt 1) { $timedOut = $true; break }
            $oldDirectory = [Environment]::CurrentDirectory
            try {
                # The GUI is extracted into a temporary runtime directory. Use
                # the user's home for relative keys and native client context.
                [Environment]::CurrentDirectory = Get-SshImportHome
                $probe = Invoke-ProxyProcess -FileName $candidate -Arguments @('-G', '-F', $snapshot.RootPath, '--', $Alias) -TimeoutSeconds ([Math]::Min(10, $remaining))
            } finally { [Environment]::CurrentDirectory = $oldDirectory }
            if ($probe.TimedOut) { $timedOut = $true; continue }
            if ($probe.ExitCode -ne 0) { continue }
            $parsed = ConvertFrom-SshImportOutput $probe.Output
            if (-not $parsed.Fields.ContainsKey('hostname') -or -not $parsed.Fields.ContainsKey('user') -or -not $parsed.Fields.ContainsKey('port')) { continue }
            $effective = $parsed; $selected = $candidate; break
        }
        if ($null -eq $effective) {
            if ($timedOut) { throw 'SSH config evaluation timed out; use manual setup.' }
            throw 'SSH could not evaluate this config. Check it locally or use manual setup; command output is not displayed.'
        }
        $fields = $effective.Fields
        $hostname = [string]$fields.hostname; $username = [string]$fields.user
        if ([string]::IsNullOrWhiteSpace($hostname) -or [string]::IsNullOrWhiteSpace($username) -or
            $hostname.Length -gt 1024 -or $username.Length -gt 1024 -or $hostname -match '[\x00-\x1f]' -or $username -match '[\x00-\x1f]') {
            throw 'SSH returned incomplete endpoint settings; use manual setup.'
        }
        Assert-PortNumber $fields.port 1 'Imported endpoint SSH port'
        $route = ('{0}@{1}:{2}' -f $username, $hostname, $fields.port)
        $jumpCount = 0
        $proxyJump = [string]$fields['proxyjump']
        $proxyCommand = [string]$fields['proxycommand']
        if ($proxyJump -and $proxyJump -ne 'none') {
            $jumpCount = @($proxyJump -split ',').Count
            $route = ('ProxyJump ' + $proxyJump + ' -> ' + $route)
        } elseif ($proxyCommand -and $proxyCommand -ne 'none') { $route = 'ProxyCommand -> ' + $route }
        # This JSON carries only UI defaults and port/monitor preferences.
        # NativeAlias/NativeConfigPath/NativeSshPath drive the real connection.
        # In particular, SSH itself selects identity files and jump endpoints.
        $profile = [pscustomobject]@{
            version = 1
            server = [pscustomobject]@{ host = $hostname; user = $username; port = [int]$fields.port; identityFile = '' }
            jumpHosts = @(); remotePort = 11082; checkIntervalSeconds = 60
        }
        return [pscustomobject]@{
            Json = ($profile | ConvertTo-Json -Depth 6 -Compress)
            Host = $hostname; User = $username; Port = [int]$fields.port; JumpCount = $jumpCount; Route = $route
            NativeAlias = $Alias; NativeConfigPath = $source; NativeSshPath = $selected
        }
    } finally {
        if ($null -ne $snapshot) {
            foreach ($path in $snapshot.Files) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
        if ([IO.Directory]::Exists($directory)) { Remove-Item -LiteralPath $directory -ErrorAction SilentlyContinue }
    }
}

function New-NativeSshArguments {
    param([string]$ConfigPath, [string]$Alias, [int]$RemotePort, [string]$ProxyUrl)
    Assert-NativeSshAlias $Alias
    $source = Assert-NativeSshLocalPath $ConfigPath
    Assert-PortNumber $RemotePort 1024 'Remote proxy port'
    $normalizedProxy = ConvertTo-LocalHttpProxyUrl $ProxyUrl
    if (-not $normalizedProxy) { throw 'Only an unauthenticated loopback HTTP proxy is supported.' }
    $uri = [Uri]$normalizedProxy
    $proxyAddress = $uri.Host
    if ($proxyAddress.Contains(':')) { $proxyAddress = '[' + $proxyAddress.Trim([char[]]'[]') + ']' }
    $forward = '127.0.0.1:' + $RemotePort + ':' + $proxyAddress + ':' + $uri.Port
    # ClearAllForwardings=yes would also erase our -R, so the snapshot strips
    # inherited forwarding rules and the invocation explicitly retains our one.
    return @('-F', $source, '-T',
        '-o', 'ClearAllForwardings=no', '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
        '-o', 'ForwardAgent=no', '-o', 'ForwardX11=no', '-o', 'PermitLocalCommand=no',
        '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3',
        '-o', 'ConnectTimeout=15', '-o', 'ConnectionAttempts=1',
        '-o', 'NumberOfPasswordPrompts=3', '-R', $forward, '--', $Alias)
}

function New-NativeActionArguments {
    param([string]$ConfigPath, [string]$Alias)
    Assert-NativeSshAlias $Alias
    $source = Assert-NativeSshLocalPath $ConfigPath
    # A settings action never reserves tunnel ports or reuses another session.
    # Its snapshot already removes forwards from every included Host block.
    return @('-F', $source, '-T', '-o', 'ClearAllForwardings=yes',
        '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
        '-o', 'ForwardAgent=no', '-o', 'ForwardX11=no', '-o', 'PermitLocalCommand=no',
        '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3',
        '-o', 'ConnectTimeout=15', '-o', 'ConnectionAttempts=1',
        '-o', 'NumberOfPasswordPrompts=3', '--', $Alias)
}
