param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [Parameter(Mandatory = $true)][string]$ResponsePath
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$utf8 = New-Object Text.UTF8Encoding $false
# In the EXE this helper is extracted beside the modules. Source-tree execution
# is also supported for deterministic, network-free integration tests.
$moduleRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $moduleRoot 'TunnelTools.ps1'))) {
    $moduleRoot = Split-Path $PSScriptRoot -Parent
}
$operation = ''
$response = $null
function Get-GuiImportFailureMessage {
    param([string]$Failure)
    $fallback = '无法安全导入该主机。请检查主机、跳板机、身份文件及不支持的 SSH 指令。'
    # Only exact messages emitted by our own importer are translated. Never
    # reflect arbitrary exception details, child stderr, command or path values.
    $known = @{
        'ssh.exe is missing. Install/enable Windows OpenSSH Client or curl; this launcher does not download software automatically.' = '未找到可用的 Windows OpenSSH 客户端。请在 Windows“可选功能”中启用 OpenSSH Client，然后重新打开软件。'
        'Configured SSH executable is missing. Check the VS Code remote.SSH.path setting.' = 'VS Code 指定的 SSH 客户端不存在或不是 EXE。请在本机 VS Code 设置中检查 remote.SSH.path，修正后点击刷新。'
        'SSH snapshot destination already exists; retry with a new session.' = '本次临时 SSH 配置已存在。请停止后重新启动连接，软件会创建新的独立配置。'
        'Network or invalid SSH config paths are unsupported; select a local file.' = 'SSH 配置路径无效或位于网络共享。请通过“选择文件”选择这台电脑上的 SSH 配置。'
        'Network SSH config paths are unsupported; select a local file.' = 'SSH 配置位于网络共享，未自动读取。请通过“选择文件”选择这台电脑上的 SSH 配置。'
        'Network or invalid SSH executable paths are unsupported; select a local file.' = 'SSH 客户端路径无效或位于网络共享。请在本机 VS Code 的 remote.SSH.path 中指定本地 SSH EXE。'
        'Cannot inspect SSH defaults safely; use manual setup.' = '无法读取 SSH 客户端的默认配置。请检查本机 ssh.exe 是否支持 ssh -G；本步骤尚未连接服务器。'
        'SSH config evaluation timed out; use manual setup.' = '读取 SSH 配置超时。请检查配置及其 Include 文件是否可在本机正常访问，然后重试。'
        'SSH could not evaluate this config. Check it locally or use manual setup; command output is not displayed.' = 'SSH 无法解析此配置。请检查所选配置文件的语法，以及软件使用的 Windows OpenSSH 是否支持其中的指令。'
        'SSH returned incomplete endpoint settings; use manual setup.' = 'SSH 返回的主机地址、用户名或端口不完整。请检查该主机配置，或点击“添加服务器”填写连接信息。'
        'Choose a literal SSH host alias without spaces or options.' = 'SSH 别名无效。请选择不含空格或命令选项的 Host 名称；也可点击“添加服务器”填写连接信息。'
        'Invalid SSH config path.' = 'SSH 配置文件路径无效。请点击“选择文件”指定本机的配置文件。'
        'SSH config file was not found. Select another config path or use manual setup.' = 'SSH 配置文件不存在。请点击“选择文件”重新选择，或点击“添加服务器”保存连接信息。'
        'An SSH config file cannot be read safely (missing, inaccessible, or over 1 MiB); use manual setup.' = 'SSH 配置或 Include 文件无法读取，可能不存在、无访问权限或超过 1 MiB。请检查文件后重试。'
        'Match exec can execute a local command during ssh -G. Automatic import is disabled; use manual setup.' = '配置包含 Match exec，会在解析时执行本机命令，因此未自动导入。请保留原配置，确认其用途后使用独立的手动服务器配置。'
        'ProxyCommand cannot be represented by this launcher. Use manual setup with explicit jump hosts.' = '配置使用 ProxyCommand，当前软件无法保留该命令的连接行为。请保留原配置；若它只是 SSH 跳板，可在“添加服务器”中填写完整跳板顺序。'
        'A jump host has a nested ProxyJump rule. Use manual setup to specify the complete ordered chain.' = '跳板机包含嵌套的 ProxyJump，当前无法自动展开。请在“添加服务器”中按实际连接顺序填写完整跳板链。'
        'At most four ProxyJump hosts are supported; use manual setup.' = 'ProxyJump 超过四级跳板，当前软件最多支持四级。请继续使用原 SSH 配置连接，或确认是否可使用更短的跳板路径。'
        'Unsupported ProxyJump endpoint syntax; use manual setup.' = 'ProxyJump 格式暂不支持。请在“添加服务器”中分别填写各级跳板的地址、用户名和端口。'
        'An explicit IdentityFile is missing; correct the path or choose a key manually.' = '配置指定的密钥文件在这台电脑上不存在。请确认本机密钥位置，在“添加服务器”中选择正确的密钥；不要上传私钥内容。'
        'Multiple existing identity files make authentication ambiguous. Choose one key with manual setup.' = '发现多个可用密钥，当前无法自动判断应使用哪一个。请在“添加服务器”中选择用于此服务器的密钥。'
        'IdentityFile none mixed with other keys requires manual setup.' = 'IdentityFile none 与其他密钥设置同时存在，无法确定认证方式。请确认该服务器所需的密钥，再建立独立的服务器配置。'
        'Relative IdentityFile paths depend on the SSH working directory; choose an absolute key path manually.' = '密钥使用相对路径，当前无法确定实际文件。请在“添加服务器”中选择本机密钥的绝对路径。'
        'Network IdentityFile paths require manual setup.' = '密钥位于网络路径，当前不自动导入。请确认认证方式后，在“添加服务器”中选择可用的本机密钥。'
        'Imported endpoint host must be an IP address or a DNS hostname, without a username, port, spaces or shell commands.' = '主机地址格式暂不支持。请在“添加服务器”中填写 IP 地址或 DNS 主机名，并把用户名与端口填入各自字段。'
        'Imported endpoint user must contain only letters, digits, underscore, dot or hyphen.' = '用户名格式暂不支持。当前允许字母、数字、下划线、点和连字符；域用户等格式请继续使用原 SSH 连接并反馈兼容需求。'
        'Imported endpoint SSH port must be an integer.' = 'SSH 端口必须是整数。请检查配置中的 Port，或在“添加服务器”中填写正确端口。'
        'Imported endpoint SSH port must be between 1 and 65535.' = 'SSH 端口需在 1–65535 之间。请检查配置中的 Port，或在“添加服务器”中填写正确端口。'
        'ProxyJump port must be an integer.' = '跳板机 SSH 端口必须是整数。请检查 ProxyJump 中的端口，或在“添加服务器”中填写各级跳板。'
        'ProxyJump port must be between 1 and 65535.' = '跳板机 SSH 端口需在 1–65535 之间。请检查 ProxyJump 中的端口，或在“添加服务器”中填写各级跳板。'
    }
    if ($known.ContainsKey($Failure)) { return $known[$Failure] }
    $keyPathFailures = @(
        'IdentityFile has unsupported path expansion; choose the key manually.'
        'IdentityFile has an incomplete token; choose the key manually.'
        'IdentityFile uses an unsupported token; choose the key manually.'
        'IdentityFile for another user is unsupported; choose the key manually.'
        'Literal percent signs in IdentityFile cannot be represented safely; choose the key manually.'
        'Invalid IdentityFile path; choose the key manually.'
        'Imported endpoint identityFile contains unsupported characters.'
    )
    if ($Failure -cin $keyPathFailures) { return '密钥路径包含当前不支持的格式或展开变量。请在“添加服务器”中直接选择本机密钥的绝对路径。' }
    if ($Failure -ceq 'Imported endpoint identityFile is not present on this computer. Reconfigure or remove that optional path.') { return $known['An explicit IdentityFile is missing; correct the path or choose a key manually.'] }
    # This is the sole dynamic diagnostic value. Validate against the importer's
    # hard-coded directive allowlist; values and arbitrary names remain private.
    if ($Failure -cmatch "\AUnsupported nondefault SSH setting '(?<setting>[a-z0-9]+)' cannot be preserved\. Use manual setup after checking authentication, routing, and host-key requirements\.\z") {
        $setting = $Matches['setting']
        if ($setting -cin @(Get-SshImportUnsupportedFields)) {
            return ('当前无法保留 SSH 设置：' + $setting + '。请保留原配置并反馈该指令名称以便兼容处理；不要直接删除认证或主机校验设置。')
        }
    }
    return $fallback
}
try {
    . (Join-Path $moduleRoot 'ProxyTools.ps1')
    . (Join-Path $moduleRoot 'TunnelTools.ps1')
    . (Join-Path $moduleRoot 'SshImport.ps1')
    $requestFile = Get-Item -LiteralPath $RequestPath -ErrorAction Stop
    if ($requestFile.Length -gt 1MB) { throw 'Request exceeds size limit.' }
    $request = [IO.File]::ReadAllText($requestFile.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $operation = [string]$request.operation
    $result = $null
    switch ($operation) {
        'list' {
            $configPath = [string]$request.sshConfig
            if (-not $configPath) { $configPath = Join-Path $env:USERPROFILE '.ssh\config' }
            $result = @(Get-NativeSshConfigAliases -ConfigPath $configPath)
        }
        'import' {
            $configPath = [string]$request.sshConfig
            if (-not $configPath) { $configPath = Join-Path $env:USERPROFILE '.ssh\config' }
            $profile = Import-SshHostProfile -Alias ([string]$request.alias) -ConfigPath $configPath -SshPath (Find-TunnelProgram ssh)
            $hops = @($profile.jumpHosts)
            $routeParts = @($hops | ForEach-Object { '{0}@{1}:{2}' -f $_.user, $_.host, $_.port })
            $routeParts += ('{0}@{1}:{2}' -f $profile.server.user, $profile.server.host, $profile.server.port)
            $result = [pscustomobject]@{
                Json = ($profile | ConvertTo-Json -Depth 6 -Compress)
                Host = [string]$profile.server.host; User = [string]$profile.server.user
                Port = [int]$profile.server.port; JumpCount = $hops.Count
                Route = $routeParts -join ' -> '
            }
        }
        'native-import' {
            $configPath = [string]$request.sshConfig
            if (-not $configPath) { $configPath = Join-Path $env:USERPROFILE '.ssh\config' }
            $result = Get-NativeSshProfile -Alias ([string]$request.alias) -ConfigPath $configPath -SshPath ([string]$request.sshPath) -PreviewDirectory ([string]$request.nativePreviewDirectory)
        }
        'validate' {
            $profile = [string]$request.profileJson | ConvertFrom-Json
            Assert-TunnelProfile $profile
            $hops = @($profile.jumpHosts)
            $routeParts = @($hops | ForEach-Object { '{0}@{1}:{2}' -f $_.user, $_.host, $_.port })
            $routeParts += ('{0}@{1}:{2}' -f $profile.server.user, $profile.server.host, $profile.server.port)
            $result = [pscustomobject]@{
                Json = ($profile | ConvertTo-Json -Depth 6 -Compress)
                Host = [string]$profile.server.host; User = [string]$profile.server.user
                Port = [int]$profile.server.port; JumpCount = $hops.Count
                Route = $routeParts -join ' -> '
            }
        }
        'probe' {
            $manualPort = [int]$request.manualPort
            if ($manualPort -lt 0 -or $manualPort -gt 65535) { throw 'Invalid proxy port.' }
            $curl = Find-TunnelProgram curl
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $candidates = @(Get-ProxyCandidates -ManualPort $manualPort)
            $result = [pscustomobject]@{ Success = $false; Url = ''; Message = '未找到通过连续两次 HTTPS 检测的本机 HTTP / Mixed 代理。'; StatusCode = 0 }
            foreach ($candidate in $candidates) {
                # Reserve two seconds for each curl watchdog; never start a
                # request that would exceed the 75-second discovery budget.
                $remaining = [int][Math]::Floor(75 - $watch.Elapsed.TotalSeconds - 2)
                if ($remaining -lt 1) { break }
                $timeout = [Math]::Min(8, $remaining)
                $first = Test-HttpProxy -ProxyUrl $candidate.Url -CurlPath $curl -TimeoutSeconds $timeout
                $result.Url = [string]$candidate.Url
                $result.StatusCode = [int]$first.StatusCode
                if (-not $first.Success) { continue }
                $remaining = [int][Math]::Floor(75 - $watch.Elapsed.TotalSeconds - 2)
                if ($remaining -lt 1) { break }
                $second = Test-HttpProxy -ProxyUrl $candidate.Url -CurlPath $curl -TimeoutSeconds ([Math]::Min(8, $remaining))
                $result.StatusCode = [int]$second.StatusCode
                if (-not $second.Success) { continue }
                $result.Success = $true
                $result.Message = if ($second.StatusCode -eq 401) { '连续两次 HTTPS 检测通过；HTTP 401 是未携带登录凭据时的预期响应。' } else { '连续两次 HTTPS 检测通过。' }
                break
            }
        }
        'prepare' {
            # The GUI sends an imported or saved profile. Validate again at
            # the persistence boundary, including the no-password field allowlist.
            $nativeMode = -not [string]::IsNullOrWhiteSpace([string]$request.nativeAlias)
            if ($nativeMode) {
                # A native profile's endpoint fields are display data. Re-evaluate
                # its local SSH reference instead of reducing authentication to
                # the manual editor's intentionally smaller schema.
                $native = Get-NativeSshProfile -Alias ([string]$request.nativeAlias) -ConfigPath ([string]$request.nativeConfigPath) -SshPath ([string]$request.nativeSshPath) -PreviewDirectory ([string]$request.nativePreviewDirectory)
                $profile = $native.Json | ConvertFrom-Json
            } else {
                $profile = [string]$request.profileJson | ConvertFrom-Json
                Assert-TunnelProfile $profile
            }
            Assert-PortNumber $request.remotePort 1024 'Remote proxy port'
            $profile.remotePort = [int]$request.remotePort
            if (-not $nativeMode) { Assert-TunnelProfile $profile }
            foreach ($destination in @([string]$request.sessionPath, [string]$request.savePath)) {
                if (-not [IO.Path]::IsPathRooted($destination)) { throw 'Profile path must be absolute.' }
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
                if ($nativeMode) {
                    $temporaryProfile = $destination + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
                    try {
                        [IO.File]::WriteAllText($temporaryProfile, ($profile | ConvertTo-Json -Depth 8), $utf8)
                        if (Test-Path -LiteralPath $destination) { [IO.File]::Replace($temporaryProfile, $destination, [NullString]::Value) }
                        else { [IO.File]::Move($temporaryProfile, $destination) }
                    } finally { if (Test-Path -LiteralPath $temporaryProfile) { Remove-Item -LiteralPath $temporaryProfile -Force } }
                } else { Save-TunnelProfile -Profile $profile -Path $destination }
            }
            $result = [pscustomobject]@{ Prepared = $true }
        }
        default { throw 'Unsupported GUI operation.' }
    }
    $response = [pscustomobject]@{ ok = $true; result = $result; message = '' }
} catch {
    # Never return raw exception text, SSH config contents or a child stderr.
    $failure = [string]$_.Exception.Message
    $message = switch ($operation) {
        'list' { '无法读取 SSH 主机列表。请检查配置文件路径、Include 文件和 Match exec 设置。' }
        'import' { Get-GuiImportFailureMessage $failure }
        'native-import' { Get-GuiImportFailureMessage $failure }
        'validate' { '服务器配置无效。请检查地址、用户名、端口、跳板机和可选密钥路径；不能保存密码或令牌。' }
        'probe' { '代理检测未完成。请确认系统 curl 可用，端口应为 0（自动）或 1–65535。' }
        'prepare' {
            if ($nativeMode) { Get-GuiImportFailureMessage $failure }
            else { '无法保存启动配置。请检查远端端口（1024–65535）、身份文件和配置目录权限。' }
        }
        default { 'GUI 请求无效。' }
    }
    $response = [pscustomobject]@{ ok = $false; result = $null; message = $message }
}
# Responses are local IPC data, never the process command line or stdout.
$json = $response | ConvertTo-Json -Depth 12 -Compress
$temporary = $ResponsePath + '.tmp'
try {
    [IO.File]::WriteAllText($temporary, $json, $utf8)
    if (Test-Path -LiteralPath $ResponsePath) { [IO.File]::Replace($temporary, $ResponsePath, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $ResponsePath) }
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
