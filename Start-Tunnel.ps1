[CmdletBinding()]
param(
    [switch]$Configure,
    [switch]$ConfigureVscode,
    [switch]$CheckOnly,
    [ValidateRange(0, 65535)][int]$ProxyPort = 0,
    [string]$ConfigPath = '',
    [string]$SshConfigPath = '',
    [string]$NativeAlias = '',
    [string]$NativeSshPath = '',
    [string]$NativeSnapshotDirectory = '',
    [switch]$ManualSetup,
    [switch]$ShowSshHelp,
    [switch]$ListSshHosts,
    [switch]$ExecutableHost,
    [string]$GuiStatusPath = '',
    [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding $false
$OutputEncoding = $utf8
try { [Console]::OutputEncoding = $utf8 } catch { }
. (Join-Path $PSScriptRoot 'TunnelTools.ps1')
. (Join-Path $PSScriptRoot 'ProxyTools.ps1')
. (Join-Path $PSScriptRoot 'SshImport.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'settings.json' }
if (-not $SshConfigPath) { $SshConfigPath = Join-Path $env:USERPROFILE '.ssh\config' }
$script:GuiStatusSequence = 0
$script:GuiStatusProxyUrl = ''
$script:GuiProxyHttpStatus = 0

function Write-GuiTunnelStatus {
    param(
        [ValidateSet('detecting','proxy-ready','connecting','ready','degraded','unverified','bind-warning','error','stopped')][string]$Phase,
        [string]$Message, [string]$ProxyUrl = '', [int]$HttpStatus = 0
    )
    if (-not $GuiStatusPath) { return }
    if ($ProxyUrl) { $script:GuiStatusProxyUrl = $ProxyUrl }
    if ($Phase -eq 'proxy-ready') { $script:GuiProxyHttpStatus = $HttpStatus }
    $script:GuiStatusSequence++
    $snapshot = [ordered]@{
        sequence = $script:GuiStatusSequence; phase = $Phase; message = $Message
        proxyUrl = $script:GuiStatusProxyUrl; httpStatus = $HttpStatus; proxyHttpStatus = $script:GuiProxyHttpStatus
    } | ConvertTo-Json -Compress
    $statusFile = [IO.Path]::GetFullPath($GuiStatusPath)
    # Each launch owns a unique status path and exactly one writer. A fixed
    # sibling lets the GUI clean it after an interrupted write.
    $temporary = $statusFile + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $snapshot, (New-Object Text.UTF8Encoding $false))
        if (Test-Path -LiteralPath $statusFile) { [IO.File]::Replace($temporary, $statusFile, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $statusFile) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function ConvertFrom-TunnelMonitorStatus {
    param([string]$Line)
    # Only the fixed remote monitor protocol enters the GUI. SSH authentication
    # prompts stay on stderr/the console and are never read or logged here.
    if ($Line -notmatch '\A(?:\[[^\]\r\n]{1,40}\]\s+)?(?<kind>TUNNEL_[A-Z_]+)(?:\s+(?<detail>[^\r\n]*))?\z') { return $null }
    $kind = $Matches['kind']; $detail = [string]$Matches['detail']
    $phase = ''; $message = ''; $http = 0
    if ($detail -match '(?:HTTP |target_http=)([0-9]{3})') { $http = [int]$Matches[1] }
    switch ($kind) {
        'TUNNEL_READY' { $phase = 'ready'; $message = '服务器 HTTPS 实测通过，隧道已就绪。' }
        'TUNNEL_RECOVERED' { $phase = 'ready'; $message = '服务器网络已恢复，隧道可继续使用。' }
        'TUNNEL_DEGRADED' { $phase = 'degraded'; $message = '服务器 HTTPS 检测未通过，连接保留并继续检查。' }
        'TUNNEL_UNVERIFIED' { $phase = 'unverified'; $message = '服务器缺少 curl，隧道已建立但网络状态尚未验证。' }
        'TUNNEL_BIND_UNVERIFIED' { $phase = 'bind-warning'; $message = '无法读取服务器监听范围；HTTPS 检测将继续。' }
        'TUNNEL_BIND_UNSAFE' { $phase = 'error'; $message = '服务器监听范围超出回环地址，本次隧道将关闭。' }
        'TUNNEL_STOPPED' { $phase = 'stopped'; $message = '远程监测已结束。' }
        'TUNNEL_HEARTBEAT' {
            if ($detail -match '\AHEALTHY\b') { $phase = 'ready'; $message = '服务器 HTTPS 心跳检查正常。' }
            elseif ($detail -match '\ADEGRADED\b') { $phase = 'degraded'; $message = '服务器 HTTPS 检测仍未通过，继续检查。' }
            elseif ($detail -match '\AUNVERIFIED\b') { $phase = 'unverified'; $message = '服务器网络状态仍未验证。' }
        }
    }
    if (-not $phase) { return $null }
    if ($phase -eq 'ready' -and $http -ne 401 -and ($http -lt 200 -or $http -gt 299)) {
        $phase = 'degraded'; $message = '服务器未返回有效的目标 HTTPS 检测结果。'
    }
    return [pscustomobject]@{ Phase = $phase; Message = $message; HttpStatus = $http }
}

function Write-VscodeActionStatus {
    param([string]$Phase, [string]$Message, [bool]$Changed = $false, [int]$Targets = 0)
    if (-not $GuiStatusPath) { return }
    $snapshot = @{ phase = $Phase; message = $Message; changed = $Changed; targets = $Targets } | ConvertTo-Json -Compress
    $statusFile = [IO.Path]::GetFullPath($GuiStatusPath)
    $temporary = $statusFile + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $snapshot, $utf8)
        if (Test-Path -LiteralPath $statusFile) { [IO.File]::Replace($temporary, $statusFile, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $statusFile) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Get-VscodeFailureMessage {
    param([string]$Code)
    switch ($Code) {
        'runtime_missing' { return '服务器未找到 VS Code 自带的 Node.js。请先用 VS Code Remote-SSH 连接一次，再点击配置。' }
        'unsupported_runtime' { return '服务器上的 Node.js 版本不支持自动配置。请更新远程 VS Code Server 后重试。' }
        'vscode_not_found' { return '未找到当前账号的远程 VS Code 设置目录。请先用 VS Code Remote-SSH 连接此服务器，再重试。' }
        'malformed_settings' { return '服务器已有 VS Code 设置存在 JSON 语法错误，原文件已保留。请在远程 VS Code 设置中修复后重试。' }
        'unsafe_path' { return '远程设置路径包含符号链接或不属于当前账号，未修改。请检查服务器 VS Code 安装目录。' }
        'settings_too_large' { return '远程 VS Code 设置文件过大，未修改。请在远程 VS Code 中检查设置文件。' }
        'concurrent_change' { return '远程设置正在被其他程序修改。请稍后重新点击配置。' }
        'write_failed' { return '服务器设置写入失败。请检查当前账号的目录权限和磁盘空间；已有文件备份保留。' }
        'partial_write' { return '部分远程设置未能安全恢复。原文件备份已保留在对应 Machine 目录（settings.json.codex-tunnel-backup-*）；请在远程 VS Code 检查设置后重试。' }
        'discovery_failed' { return '无法确认当前账号的远程 VS Code 目录。请先使用 VS Code Remote-SSH 连接一次后重试。' }
        'invalid_port' { return '远端代理端口无效，请检查软件高级设置。' }
        default { return '远程 VS Code 配置未完成，请检查 SSH 登录和服务器设置目录后重试。' }
    }
}

function Show-SshLookupHelp {
    Write-Host "`n查询 SSH 连接信息（在本机 PowerShell 中运行）" -ForegroundColor Cyan
    Write-Host @'
1. 打开当前 Windows 用户的 SSH 配置：
   notepad "$env:USERPROFILE\.ssh\config"

2. 把 YOUR_ALIAS 换成 Host 后面的别名，查询最终生效的连接信息：
   ssh -G YOUR_ALIAS | Select-String '^(hostname|user|port|proxyjump|identityfile) '

3. 如果 VS Code 使用自定义 SSH 配置路径：
   ssh -G -F "D:\path\to\ssh_config" YOUR_ALIAS | Select-String '^(hostname|user|port|proxyjump|identityfile) '

Host 是选择用的别名，hostname 是地址，user 是用户名，port 是 SSH 端口。
proxyjump 中的多台跳板机按逗号顺序连接；每个跳板别名也可用 ssh -G 查询。
没有 proxyjump 一行通常表示没有 ProxyJump；若原配置使用 ProxyCommand，则需按原连接方式处理。
VS Code 自定义路径可在本机设置中搜索 remote.SSH.configFile 查看。
ssh -G 不登录服务器，但会执行你自己配置的 Match exec；请仅对可信配置手动运行。

如果已经登录服务器，可查询：
   whoami
   hostname -I
这会显示用户名和服务器网卡地址；内网 IP 不一定能从当前电脑直接访问。
能正常使用的 SSH 配置中的 HostName / ProxyJump 更适合填写本启动器。
'@
}

function Select-SshProfile {
    param([string]$InitialPath)
    $sourcePath = $InitialPath
    while ($true) {
        Write-Host "`n从本机 SSH 配置选择服务器：$sourcePath" -ForegroundColor Cyan
        $aliases = @()
        try { $aliases = @(Get-SshConfigAliases -ConfigPath $sourcePath) }
        catch { Write-Host ('无法列出此配置：' + $_.Exception.Message) -ForegroundColor Yellow }
        for ($i = 0; $i -lt $aliases.Count; $i++) {
            Write-Host ('  [{0}] {1}' -f ($i + 1), $aliases[$i].Alias)
        }
        if ($aliases.Count -eq 0) { Write-Host '没有找到可列出的服务器别名；可选择其他配置文件或手动填写。' }
        Write-Host '  [A] 输入 SSH 别名（适合通配符规则）  [C] 选择其他 SSH 配置文件'
        Write-Host '  [M] 手动填写  [H] 查看查询命令  [Q] 退出'
        $choice = Read-SetupText '输入服务器编号或选项' 'M'
        if ($choice -ieq 'M') { return $null }
        if ($choice -ieq 'Q') { throw '已取消配置，没有保存更改。' }
        if ($choice -ieq 'H') { Show-SshLookupHelp; continue }
        if ($choice -ieq 'C') {
            $sourcePath = (Read-SetupText 'SSH 配置文件完整路径' $sourcePath).Trim('"')
            if ($sourcePath -match '^~[/\\]') { $sourcePath = Join-Path $env:USERPROFILE $sourcePath.Substring(2) }
            continue
        }
        $selectedAlias = ''
        if ($choice -ieq 'A') { $selectedAlias = Read-SetupText '输入平时 ssh 后面的主机别名（不含 ssh 或用户名）' }
        elseif ($choice -match '\A[0-9]{1,5}\z' -and [int]$choice -ge 1 -and [int]$choice -le $aliases.Count) {
            $selectedAlias = $aliases[[int]$choice - 1].Alias
        } else { Write-Host '请输入列表中的编号或 A / C / M / H / Q。' -ForegroundColor Yellow; continue }
        try {
            $imported = Import-SshHostProfile -Alias $selectedAlias -ConfigPath $sourcePath -SshPath (Find-TunnelProgram 'ssh')
            Write-Host "`n已从 SSH 别名 $selectedAlias 导入：" -ForegroundColor Green
            Write-Host ('  服务器：{0}@{1}  SSH 端口 {2}' -f $imported.server.user, $imported.server.host, $imported.server.port)
            $number = 0
            foreach ($jump in @($imported.jumpHosts)) {
                $number++
                Write-Host ('  跳板 {0}：{1}@{2}  SSH 端口 {3}' -f $number, $jump.user, $jump.host, $jump.port)
            }
            if (@($imported.jumpHosts).Count -eq 0) { Write-Host '  无 ProxyJump 跳板机。' }
            Write-Host '连接信息将保存到本工具的独立设置文件；原 SSH 配置中的端口转发不会复制。'
            return $imported
        } catch {
            Write-Host ('此主机无法自动导入：' + $_.Exception.Message) -ForegroundColor Yellow
            Write-Host '可选择其他主机、输入 H 查看查询方法，或输入 M 手动填写。'
        }
    }
}

function Read-SetupText {
    param([string]$Label, [string]$Default = '', [switch]$Optional)
    $hint = if ($Default) { " [$Default]" } else { '' }
    while ($true) {
        $value = (Read-Host ($Label + $hint)).Trim()
        if (-not $value) { $value = $Default }
        if ($value -or $Optional) { return $value }
        Write-Host '这一项不能为空。' -ForegroundColor Yellow
    }
}

function Read-SetupNumber {
    param([string]$Label, [int]$Default, [int]$Minimum, [int]$Maximum)
    while ($true) {
        $value = Read-SetupText $Label ([string]$Default)
        if ($value -match '\A[0-9]{1,5}\z' -and [int]$value -ge $Minimum -and [int]$value -le $Maximum) { return [int]$value }
        Write-Host "请输入 $Minimum 到 $Maximum 之间的整数。" -ForegroundColor Yellow
    }
}

function Read-SetupEndpoint {
    param([string]$Label, $Previous)
    while ($true) {
        Write-Host "`n$Label" -ForegroundColor Cyan
        $oldHost = if ($Previous) { [string]$Previous.host } else { '' }
        $oldUser = if ($Previous) { [string]$Previous.user } else { '' }
        $oldPort = if ($Previous) { [int]$Previous.port } else { 22 }
        $oldIdentity = if ($Previous) { [string]$Previous.identityFile } else { '' }
        $serverName = Read-SetupText '地址（IP 或完整域名，不含用户名和端口）' $oldHost
        $userName = Read-SetupText 'SSH 用户名' $oldUser
        $sshPort = Read-SetupNumber 'SSH 端口' $oldPort 1 65535
        $identity = Read-SetupText '私钥文件路径（留空用默认密钥/密码；输入 - 清空）' $oldIdentity -Optional
        if ($identity -eq '-') { $identity = '' }
        if ($identity) { $identity = $identity.Trim('"') }
        $endpoint = [pscustomobject]@{ host = $serverName; user = $userName; port = $sshPort; identityFile = $identity }
        try { Assert-SshEndpoint $endpoint $Label; return $endpoint }
        catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }
}

function Invoke-SetupWizard {
    param([string]$Path)
    Write-Host "`n首次使用或更换服务器：配置向导" -ForegroundColor Cyan
    Write-Host '只保存连接地址和端口等信息；不要在任何配置项里填写密码。'
    $old = $null
    if (Test-Path -LiteralPath $Path) {
        try { $old = Read-TunnelProfile $Path }
        catch { Write-Host '旧配置无效，将重新填写。' -ForegroundColor Yellow }
    }
    $imported = if ($ManualSetup) { $null } else { Select-SshProfile -InitialPath $SshConfigPath }
    if ($imported) {
        $server = $imported.server
        $jumps = @($imported.jumpHosts)
    } else {
        $previousServer = if ($old) { $old.server } else { $null }
        $server = Read-SetupEndpoint '目标服务器' $previousServer
        $oldCount = if ($old) { @($old.jumpHosts).Count } else { 0 }
        $jumpCount = Read-SetupNumber '需要几台跳板机？直接连接填 0' $oldCount 0 4
        $jumps = @()
        for ($i = 0; $i -lt $jumpCount; $i++) {
            $previousJump = if ($old -and $i -lt @($old.jumpHosts).Count) { @($old.jumpHosts)[$i] } else { $null }
            $jumps += Read-SetupEndpoint ("第 {0} 台跳板机（按从本机到服务器的顺序）" -f ($i + 1)) $previousJump
        }
    }
    $previousRemotePort = if ($old) { [int]$old.remotePort } else { 11082 }
    $remotePort = Read-SetupNumber '服务器上的代理入口端口（通常保持 11082）' $previousRemotePort 1024 65535
    $profile = [pscustomobject]@{
        version = 1; server = $server; jumpHosts = $jumps
        remotePort = $remotePort; checkIntervalSeconds = 60
    }
    Save-TunnelProfile -Profile $profile -Path $Path
    Write-Host "配置已保存：$Path" -ForegroundColor Green
    return $profile
}

function Find-WorkingProxy {
    param([string]$CurlPath, [int]$Port)
    Write-GuiTunnelStatus 'detecting' '正在查找并检测本机 HTTP/Mixed 代理。'
    $candidates = @(Get-ProxyCandidates -ManualPort $Port)
    if ($candidates.Count -eq 0) {
        Write-Host '没有找到可检测的本地代理端口。请先启动代理软件并启用 HTTP 或 Mixed 监听。' -ForegroundColor Yellow
        return $null
    }
    Write-Host "发现 $($candidates.Count) 个候选入口；将实测 OpenAI HTTPS（不发送登录凭据）。"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    foreach ($candidate in $candidates) {
        if ($watch.Elapsed.TotalSeconds -gt 75) {
            Write-Host '自动检测已达到时间上限，可手动指定代理端口继续。' -ForegroundColor Yellow
            break
        }
        Write-Host ("检测 {0}  来源：{1}" -f $candidate.Url, $candidate.Source)
        Write-GuiTunnelStatus 'detecting' ("正在检测本机代理 {0}。" -f $candidate.Url)
        $result = Test-HttpProxy -ProxyUrl $candidate.Url -CurlPath $CurlPath -TimeoutSeconds 8
        if (-not $result.Success) {
            Write-Host ("  未通过：{0}" -f $result.Message) -ForegroundColor DarkYellow
            continue
        }
        # One extra independent request helps expose an immediately flaky route.
        $confirmation = Test-HttpProxy -ProxyUrl $candidate.Url -CurlPath $CurlPath -TimeoutSeconds 8
        if ($confirmation.Success) {
            Write-Host ("本机代理验证通过：{0}，目标 HTTP {1}（连续两次）。" -f $candidate.Url, $confirmation.StatusCode) -ForegroundColor Green
            Write-GuiTunnelStatus 'proxy-ready' '本机代理 HTTPS 连续两次检测通过；服务器隧道尚未验证。' $candidate.Url $confirmation.StatusCode
            return $candidate.Url
        }
        Write-Host ("  复测失败：{0}" -f $confirmation.Message) -ForegroundColor Yellow
    }
    return $null
}

$sessionDirectory = $null
$sessionSshConfigPath = $null
$nativeSnapshot = $null
$resultCode = 0
try {
    Write-Host 'Codex SSH 代理隧道 · 便携启动器' -ForegroundColor Cyan
    Write-Host '不修改本地 Codex、全局 SSH 配置、系统代理或环境变量。'
    # The GUI child starts in its extracted runtime directory. Native SSH keys
    # and helper commands should instead resolve relative to the user's home.
    if ($NativeAlias) { Set-Location -LiteralPath ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) }
    if ($ShowSshHelp) { Show-SshLookupHelp; exit 0 }
    if ($ListSshHosts) {
        Get-SshConfigAliases -ConfigPath $SshConfigPath | Format-Table Alias, SourceFile -AutoSize
        exit 0
    }
    if ($Configure -and $CheckOnly) { throw 'Choose Configure or CheckOnly, not both.' }
    if ($ConfigureVscode -and ($Configure -or $CheckOnly -or $ManualSetup)) { throw 'ConfigureVscode cannot be combined with setup or proxy checks.' }
    $profile = $null
    if (-not $CheckOnly) {
        if ($NativeAlias) {
            if ($Configure -or $ManualSetup) { throw 'Native SSH mode cannot be combined with manual setup.' }
            $nativePreview = Get-NativeSshProfile -Alias $NativeAlias -ConfigPath $SshConfigPath -SshPath $NativeSshPath -PreviewDirectory $NativeSnapshotDirectory
            $requested = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            Assert-PortNumber $requested.remotePort 1024 'Remote proxy port'
            if ([string]$requested.checkIntervalSeconds -notmatch '\A[0-9]{1,5}\z' -or [int]$requested.checkIntervalSeconds -lt 10 -or [int]$requested.checkIntervalSeconds -gt 86400) { throw 'Invalid native monitor interval.' }
            $profile = $nativePreview.Json | ConvertFrom-Json
            $profile.remotePort = [int]$requested.remotePort
            $profile.checkIntervalSeconds = [int]$requested.checkIntervalSeconds
        } elseif ($Configure -or -not (Test-Path -LiteralPath $ConfigPath)) {
            if ($NoPrompt) {
                if ($ExecutableHost) { throw 'No valid profile. Use menu 2 or --configure first.' }
                throw 'No valid profile. Run Configure.cmd first.'
            }
            $profile = Invoke-SetupWizard $ConfigPath
        } else { $profile = Read-TunnelProfile $ConfigPath }
    }
    if ($ConfigureVscode) {
        # This is a separate SSH action: no proxy probe, no reverse forward,
        # and no shared control connection or local/global settings changes.
        if ($NativeAlias) {
            $ssh = $nativePreview.NativeSshPath
            $sessionDirectory = if ($NativeSnapshotDirectory) { [IO.Path]::GetFullPath($NativeSnapshotDirectory) } else { Join-Path ([IO.Path]::GetTempPath()) ('CodexProxyTunnel-' + [guid]::NewGuid().ToString('N')) }
            $nativeSnapshot = New-NativeTunnelConfig -ConfigPath $SshConfigPath -DestinationDirectory $sessionDirectory
            $sessionSshConfigPath = $nativeSnapshot.RootPath
            $sshArguments = @(New-NativeActionArguments -ConfigPath $sessionSshConfigPath -Alias $NativeAlias)
        } else {
            $ssh = Find-TunnelProgram 'ssh'
            $sessionDirectory = if ($NativeSnapshotDirectory) { [IO.Path]::GetFullPath($NativeSnapshotDirectory) } else { Join-Path ([IO.Path]::GetTempPath()) ('CodexProxyTunnel-' + [guid]::NewGuid().ToString('N')) }
            [void][IO.Directory]::CreateDirectory($sessionDirectory)
            $sessionSshConfigPath = Join-Path $sessionDirectory 'config-000.conf'
            [IO.File]::WriteAllText($sessionSshConfigPath, (New-TunnelSshConfig -Profile $profile -NoForward), $utf8)
            $sshArguments = @('-F', $sessionSshConfigPath, '-T', '-o', 'ClearAllForwardings=yes', 'portable-target')
        }
        $payload = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'remote-vscode-config.sh'), $utf8)
        $javascript = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'remote-vscode-config.js'), $utf8)
        if (-not $payload.Contains('__CODEX_TUNNEL_VSCODE_JS__')) { throw 'Remote settings payload is incomplete.' }
        $payload = $payload.Replace('__CODEX_TUNNEL_VSCODE_JS__', $javascript).Replace("`r`n", "`n").Replace("`r", "`n")
        $remoteCommand = Get-RemoteVscodeCommand -Port $profile.remotePort
        Write-VscodeActionStatus 'connecting' '正在连接所选服务器并配置远程 VS Code，请在此窗口完成 SSH 身份验证。'
        Write-Host "`n为 $($profile.server.user)@$($profile.server.host) 配置远程 VS Code 代理。" -ForegroundColor Cyan
        Write-Host '如有提示，请输入服务器/跳板机密码或验证码。已有隧道保持运行。'
        Write-Host ('只更新服务器 VS Code 的代理为 http://127.0.0.1:' + $profile.remotePort + '，保留其他设置并备份原文件。')
        $actionResult = $null
        $actionError = ''
        $payload | & $ssh @sshArguments $remoteCommand | ForEach-Object {
            $line = [string]$_
            if ($line -match '\AVSCODE_CONFIGURED changed=([01]) targets=([1-9][0-9]{0,2})\z') {
                if ([int]$Matches[2] -le 128) { $actionResult = @{ Changed = $Matches[1] -eq '1'; Targets = [int]$Matches[2] } }
            } elseif ($line -match '\AVSCODE_ERROR code=([a-z_]{1,40})\z') {
                $actionError = Get-VscodeFailureMessage $Matches[1]
            }
            # Never copy arbitrary server text or settings contents into GUI logs.
        }
        $sshExit = $LASTEXITCODE
        if ($sshExit -eq 0 -and $null -ne $actionResult -and -not $actionError) {
            Write-VscodeActionStatus 'configured' '远程 VS Code 代理已配置，请重新加载远程窗口。' $actionResult.Changed $actionResult.Targets
            Write-Host '完成。请回到远程 VS Code，运行“Developer: Reload Window / 开发人员: 重新加载窗口”。' -ForegroundColor Green
        } else {
            if (-not $actionError) { $actionError = '远程 VS Code 配置未完成。请检查 SSH 窗口中的连接或身份验证提示后重试。' }
            Write-VscodeActionStatus 'error' $actionError
            Write-Host $actionError -ForegroundColor Red
            $resultCode = 1
        }
    } elseif (-not $Configure) {
        $curl = Find-TunnelProgram 'curl'
        $proxy = Find-WorkingProxy -CurlPath $curl -Port $ProxyPort
        if (-not $proxy -and -not $NoPrompt) {
            Write-Host "`n无法自动找到可用 HTTP 代理。仅有 TUN/SOCKS/PAC 时，请在代理软件里启用 HTTP/Mixed 端口。" -ForegroundColor Yellow
            $manual = Read-Host '输入实际 HTTP/Mixed 端口重试，或直接回车退出'
            if ($manual) {
                Assert-PortNumber $manual
                $proxy = Find-WorkingProxy -CurlPath $curl -Port ([int]$manual)
            }
        }
        if (-not $proxy) { throw 'No verified local HTTP proxy. Check the proxy port, node and network, then retry. No SSH tunnel was started.' }
        if ($CheckOnly) {
            Write-Host "`n本机检测完成。此模式尚未建立 SSH 隧道，也没有验证 Codex 登录或模型调用。" -ForegroundColor Green
            if ($ExecutableHost) { Write-Host '返回主菜单选择 1 启动隧道；服务器实测通过才会显示 TUNNEL_READY。' }
            else { Write-Host '双击 Start.cmd 后，服务器实测通过才会显示 TUNNEL_READY。' }
        } else {
            if ($NativeAlias) {
                $ssh = $nativePreview.NativeSshPath
                $sessionDirectory = if ($NativeSnapshotDirectory) { [IO.Path]::GetFullPath($NativeSnapshotDirectory) } else { Join-Path ([IO.Path]::GetTempPath()) ('CodexProxyTunnel-' + [guid]::NewGuid().ToString('N')) }
                $nativeSnapshot = New-NativeTunnelConfig -ConfigPath $SshConfigPath -DestinationDirectory $sessionDirectory
                $sessionSshConfigPath = $nativeSnapshot.RootPath
                $sshArguments = @(New-NativeSshArguments -ConfigPath $sessionSshConfigPath -Alias $NativeAlias -RemotePort $profile.remotePort -ProxyUrl $proxy)
            } else {
                $ssh = Find-TunnelProgram 'ssh'
                $sessionDirectory = Join-Path ([IO.Path]::GetTempPath()) ('CodexProxyTunnel-' + [guid]::NewGuid().ToString('N'))
                [void][IO.Directory]::CreateDirectory($sessionDirectory)
                $sessionSshConfigPath = Join-Path $sessionDirectory 'ssh_config'
                [IO.File]::WriteAllText($sessionSshConfigPath, (New-TunnelSshConfig -Profile $profile -ProxyUrl $proxy), $utf8)
                $sshArguments = @('-F', $sessionSshConfigPath, '-T', 'portable-target')
            }
            $monitor = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'remote-monitor.sh'), $utf8)
            $remoteCommand = Get-RemoteMonitorCommand -Port $profile.remotePort -Interval $profile.checkIntervalSeconds
            Write-GuiTunnelStatus 'connecting' '正在连接服务器，请在 SSH 终端窗口完成密码、验证码或主机指纹确认。' $proxy
            Write-Host "`n目标：$($profile.server.user)@$($profile.server.host):$($profile.server.port)"
            Write-Host "路线：服务器 127.0.0.1:$($profile.remotePort) -> SSH -> 本机 $proxy"
            Write-Host '按 SSH 提示在本窗口输入密码/验证码。首次连接请核对服务器指纹。'
            Write-Host 'TUNNEL_READY = 服务器 HTTPS 实测通过；DEGRADED = 检测未通过；UNVERIFIED = 缺少检测工具。'
            Write-Host '窗口保持打开，Ctrl+C 停止本次隧道。退出后不会自动重连或抢占已有端口。'
            Write-Host "`n在服务器 VS Code 的 Remote Settings (JSON) 合并以下两项：" -ForegroundColor Cyan
            Write-Host '  "http.useLocalProxyConfiguration": false,'
            Write-Host ('  "http.proxy": "http://127.0.0.1:' + $profile.remotePort + '"')
            Write-Host ''
            # Foreground native SSH retains its console for password/MFA prompts.
            # Only the fixed monitor script goes to stdin; passwords are never captured.
            if ($GuiStatusPath) {
                $monitor | & $ssh @sshArguments $remoteCommand | ForEach-Object {
                    $line = [string]$_
                    Write-Host $line
                    $status = ConvertFrom-TunnelMonitorStatus $line
                    if ($null -ne $status) { Write-GuiTunnelStatus $status.Phase $status.Message $proxy $status.HttpStatus }
                }
            } else {
                $monitor | & $ssh @sshArguments $remoteCommand
            }
            $sshExit = $LASTEXITCODE
            if ($sshExit -ne 0) {
                Write-Host "`nSSH 已结束，退出码 $sshExit。" -ForegroundColor Yellow
                if ($sshExit -eq 78) {
                    Write-Host '服务器实际监听地址超出了回环范围，本次隧道已关闭。请管理员检查 sshd 的 GatewayPorts 设置（no 或 clientspecified）。'
                } else {
                    Write-Host "若出现 remote port forwarding failed，先停止占用服务器 $($profile.remotePort) 的旧隧道，再启动本窗口。"
                    Write-Host '若是 Permission denied 或连接失败，请检查服务器/跳板机信息和 SSH 登录方式。'
                }
                $resultCode = 1
                Write-GuiTunnelStatus 'error' ("SSH 连接已结束（退出码 {0}），请查看登录窗口中的连接或认证提示。" -f $sshExit)
            } else {
                Write-GuiTunnelStatus 'stopped' 'SSH 连接已结束。'
            }
        }
    }
} catch {
    Write-Host ("`n启动未完成：" + $_.Exception.Message) -ForegroundColor Red
    if ($GuiStatusPath) { Write-Host '可返回图形界面选择服务器、检测代理后重新启动。' }
    elseif ($ExecutableHost) { Write-Host '可在主菜单选择 2 更换服务器，或选择 3 单独检查本机代理。' }
    else { Write-Host '可双击 Configure.cmd 更换服务器，或 Check.cmd 单独检查本机代理。' }
    $resultCode = 1
    try {
        if ($ConfigureVscode) { Write-VscodeActionStatus 'error' '远程 VS Code 配置未完成。请查看 SSH 窗口中的网络或配置提示后重试。' }
        else { Write-GuiTunnelStatus 'error' '启动未完成。请查看 SSH 窗口中的网络或配置提示，再返回图形界面重试。' }
    } catch { }
} finally {
    if ($null -ne $nativeSnapshot) {
        foreach ($snapshotFile in $nativeSnapshot.Files) {
            $resolvedSnapshot = [IO.Path]::GetFullPath($snapshotFile)
            if ([IO.Path]::GetDirectoryName($resolvedSnapshot) -eq [IO.Path]::GetFullPath($sessionDirectory) -and [IO.Path]::GetFileName($resolvedSnapshot) -match '\Aconfig-[0-9]{3}\.conf\z') {
                if (Test-Path -LiteralPath $resolvedSnapshot -PathType Leaf) { Remove-Item -LiteralPath $resolvedSnapshot -Force -ErrorAction SilentlyContinue }
            }
        }
    }
    # Delete only this invocation's known temporary file and empty directory.
    if ($sessionSshConfigPath -and (Test-Path -LiteralPath $sessionSshConfigPath)) { Remove-Item -LiteralPath $sessionSshConfigPath -Force -ErrorAction SilentlyContinue }
    if ($sessionDirectory -and (Test-Path -LiteralPath $sessionDirectory)) { Remove-Item -LiteralPath $sessionDirectory -ErrorAction SilentlyContinue }
}
exit $resultCode
