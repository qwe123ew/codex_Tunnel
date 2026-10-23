param([string]$ApiPath = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $ApiPath) { $ApiPath = Join-Path $root 'gui\Gui-Api.ps1' }
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$utf8 = New-Object Text.UTF8Encoding $false
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('codex-import-diagnostics-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
$script:passed = 0
$script:requests = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
function Write-Fixture([string]$Name, [string]$Contents) {
    $path = Join-Path $scratch $Name
    [IO.File]::WriteAllText($path, $Contents, $utf8)
    return $path
}
function Invoke-Import([string]$Config, [string]$Alias = 'target', [string]$Helper = $ApiPath) {
    $script:requests++
    $requestPath = Join-Path $scratch ('request-' + $script:requests + '.json')
    $responsePath = Join-Path $scratch ('response-' + $script:requests + '.json')
    [IO.File]::WriteAllText($requestPath, (@{ operation = 'import'; alias = $Alias; sshConfig = $Config } | ConvertTo-Json), $utf8)
    $printed = @(& $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Helper -RequestPath $requestPath -ResponsePath $responsePath 2>&1)
    Assert-True ($LASTEXITCODE -eq 0 -and $printed.Count -eq 0) 'helper responds silently without leaking stderr'
    $raw = [IO.File]::ReadAllText($responsePath, [Text.Encoding]::UTF8)
    Assert-True (-not $raw.Contains('NEVER-ECHO-THIS-SECRET')) 'response never exposes command text, path or unknown exception'
    $response = $raw | ConvertFrom-Json
    Assert-True (-not $response.ok -and $null -eq $response.result) 'failed import cannot produce a startable profile'
    return $response
}
function Assert-Cause($Response, [string]$Pattern, [string]$Label) {
    Assert-True ($Response.message -match $Pattern) $Label
}
try {
    # These execute the actual importer and local ssh -G; no login or network.
    # Losing the cause at the API boundary must fail these tests.
    $config = Write-Fixture 'unsupported.conf' "Host target`n HostName server.example.org`n User researcher`n IdentityFile none`n IdentitiesOnly yes`n"
    $before = [IO.File]::ReadAllText($config)
    Assert-Cause (Invoke-Import $config) 'identitiesonly' 'nondefault authentication setting is identified instead of a generic error'
    Assert-True ([IO.File]::ReadAllText($config) -ceq $before) 'import diagnostics preserve SSH configuration bytes'
    $config = Write-Fixture 'hostkey.conf' "Host target`n User researcher`n IdentityFile none`n StrictHostKeyChecking no`n"
    Assert-Cause (Invoke-Import $config) 'stricthostkeychecking' 'host-key requirement names only the supported diagnostic directive'
    $missingKey = (Join-Path $scratch 'NEVER-ECHO-THIS-SECRET-missing-key').Replace('\', '/')
    $config = Write-Fixture 'missing-key.conf' "Host target`n User researcher`n IdentityFile `"$missingKey`"`n"
    Assert-Cause (Invoke-Import $config) '密钥.*不存在|找不到.*密钥' 'new-computer missing explicit key has a concrete remedy'
    $key1 = (Write-Fixture 'key-one' 'test marker only').Replace('\', '/')
    $key2 = (Write-Fixture 'key-two' 'test marker only').Replace('\', '/')
    $config = Write-Fixture 'multiple-keys.conf' "Host target`n User researcher`n IdentityFile `"$key1`"`n IdentityFile `"$key2`"`n"
    Assert-Cause (Invoke-Import $config) '多个.*密钥' 'ambiguous keys are explained without exposing their paths'
    $config = Write-Fixture 'proxy-command.conf' "Host target`n User researcher`n IdentityFile none`n ProxyCommand NEVER-ECHO-THIS-SECRET --token private`n"
    Assert-Cause (Invoke-Import $config) 'ProxyCommand' 'unsupported command routing is named without printing the command'
    $config = Write-Fixture 'nested-jumps.conf' "Host target`n User researcher`n ProxyJump gate`nHost gate`n User researcher`n ProxyJump outer`nHost *`n IdentityFile none`n"
    Assert-Cause (Invoke-Import $config) '嵌套.*ProxyJump|ProxyJump.*嵌套' 'nested jump routing has a distinct diagnostic'
    $config = Write-Fixture 'invalid-config.conf' "Host target`n User researcher`n CodexUnknownOption NEVER-ECHO-THIS-SECRET`n"
    Assert-Cause (Invoke-Import $config) 'SSH.*解析|SSH.*配置.*无效' 'ssh config evaluation failure is distinct from discovery'
    $config = Write-Fixture 'safe.conf' "Host target`n User researcher`n IdentityFile none`n"
    Assert-Cause (Invoke-Import $config '--NEVER-ECHO-THIS-SECRET') '别名' 'invalid alias diagnostic does not reflect submitted alias'
    Assert-Cause (Invoke-Import (Join-Path $scratch 'absent.conf')) '配置文件.*不存在|找不到.*配置文件' 'missing config has a file selection remedy'
    $marker = Join-Path $scratch 'MATCH-EXEC-RAN'
    $config = Write-Fixture 'match-exec.conf' ("Host target`n User researcher`nMatch exec `"cmd.exe /c echo NEVER-ECHO-THIS-SECRET>$($marker.Replace('\', '/'))`"`n")
    Assert-Cause (Invoke-Import $config) 'Match exec' 'executable match diagnostic preserves preflight rejection'
    Assert-True (-not (Test-Path -LiteralPath $marker)) 'diagnostics never execute Match exec'
    $config = Write-Fixture 'invalid-host.conf' "Host target`n HostName invalid_name`n User researcher`n IdentityFile none`n"
    Assert-Cause (Invoke-Import $config) '主机地址' 'unsupported hostname has a concrete endpoint diagnostic'
    $config = Write-Fixture 'invalid-user.conf' "Host target`n User user@domain`n IdentityFile none`n"
    Assert-Cause (Invoke-Import $config) '用户名' 'unsupported username has a concrete endpoint diagnostic'

    # Unavailable executable/timeouts and unexpected exceptions cannot be induced
    # safely through real machine state. Isolate helper dependencies in this temp
    # folder; keep the real production API catch and serialization boundary.
    $fixtureDir = Join-Path $scratch 'runtime'
    [void][IO.Directory]::CreateDirectory($fixtureDir)
    $fixtureApi = Join-Path $fixtureDir 'Gui-Api.ps1'
    Copy-Item -LiteralPath $ApiPath -Destination $fixtureApi
    [IO.File]::WriteAllText((Join-Path $fixtureDir 'ProxyTools.ps1'), '# no external processes in exceptional fixtures', $utf8)
    $fakeTools = 'function Find-TunnelProgram { param($Name); return "fixture-ssh" }'
    [IO.File]::WriteAllText((Join-Path $fixtureDir 'TunnelTools.ps1'), $fakeTools, $utf8)
    $cases = @(
        ,@("Cannot inspect SSH defaults safely; use manual setup.", 'SSH.*默认', 'defaults evaluation failure')
        ,@("SSH config evaluation timed out; use manual setup.", '超时', 'bounded evaluation timeout')
        ,@("SSH returned incomplete endpoint settings; use manual setup.", '不完整|缺少', 'incomplete endpoint output')
        ,@("Relative IdentityFile paths depend on the SSH working directory; choose an absolute key path manually.", '绝对路径', 'relative key-path remedy')
        ,@("IdentityFile none mixed with other keys requires manual setup.", 'IdentityFile none', 'mixed disabled and explicit keys')
        ,@("At most four ProxyJump hosts are supported; use manual setup.", '四|4', 'jump-count limit')
        ,@("Unsupported ProxyJump endpoint syntax; use manual setup.", 'ProxyJump.*格式|ProxyJump.*语法', 'jump syntax')
        ,@("Imported endpoint SSH port must be between 1 and 65535.", 'SSH 端口', 'validated endpoint port')
        ,@("NEVER-ECHO-THIS-SECRET unexpected failure", '无法安全导入该主机', 'unknown exception remains generic')
        ,@("Unsupported nondefault SSH setting 'NEVER-ECHO-THIS-SECRET' cannot be preserved. Use manual setup after checking authentication, routing, and host-key requirements.", '无法安全导入该主机', 'forged directive is not reflected')
        ,@("Unsupported nondefault SSH setting 'notallowed' cannot be preserved. Use manual setup after checking authentication, routing, and host-key requirements.", '无法安全导入该主机', 'syntactically valid but unlisted directive stays generic')
        ,@("An explicit IdentityFile is missing; correct the path or choose a key manually. NEVER-ECHO-THIS-SECRET", '无法安全导入该主机', 'trusted-message prefix alone cannot disclose unknown errors')
    )
    foreach ($case in $cases) {
        $literal = ([string]$case[0]).Replace("'", "''")
        $module = "function Get-SshImportUnsupportedFields { return @('identitiesonly', 'stricthostkeychecking') }`nfunction Import-SshHostProfile { throw '$literal' }`n"
        [IO.File]::WriteAllText((Join-Path $fixtureDir 'SshImport.ps1'), $module, $utf8)
        Assert-Cause (Invoke-Import '' 'target' $fixtureApi) ([string]$case[1]) ([string]$case[2])
    }
    $missingSsh = 'function Find-TunnelProgram { throw "ssh.exe is missing. Install/enable Windows OpenSSH Client or curl; this launcher does not download software automatically." }'
    [IO.File]::WriteAllText((Join-Path $fixtureDir 'TunnelTools.ps1'), $missingSsh, $utf8)
    Assert-Cause (Invoke-Import '' 'target' $fixtureApi) 'OpenSSH.*客户端|OpenSSH Client' 'missing SSH client gives the actionable Windows component name'
} finally {
    $fullScratch = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($fullScratch.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $fullScratch -Recurse -Force }
}
Write-Host "PASS: $script:passed GUI import diagnostic checks ($script:requests API requests; local fixtures only)"
