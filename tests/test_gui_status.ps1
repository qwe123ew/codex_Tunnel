$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tokens = $null; $parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Start-Tunnel.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Write-GuiTunnelStatus', 'ConvertFrom-TunnelMonitorStatus')) {
    $definition = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$passed = 0
function Check($condition, $message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:passed++
}
foreach ($line in @('Password: never-log-this', 'HTTP/1.1 200 Connection established', 'Welcome to the server', 'TUNNEL_UNKNOWN private')) {
    Check ($null -eq (ConvertFrom-TunnelMonitorStatus $line)) 'ignore non-monitor or authentication text'
}
Check ((ConvertFrom-TunnelMonitorStatus '[2026-10-23T01:02:03Z] TUNNEL_READY remote HTTPS verified (HTTP 401); login not tested.').Phase -eq 'ready') 'remote 401 ready'
Check ((ConvertFrom-TunnelMonitorStatus 'TUNNEL_HEARTBEAT HEALTHY target_http=204').Phase -eq 'ready') 'healthy target 2xx heartbeat'
Check ((ConvertFrom-TunnelMonitorStatus 'TUNNEL_RECOVERED remote target TLS/HTTP restored (HTTP 401).').Phase -eq 'ready') 'recovery clears degraded state'
Check ((ConvertFrom-TunnelMonitorStatus 'TUNNEL_READY response (HTTP 403)').Phase -eq 'degraded') '403 is not ready even with a ready label'
Check ((ConvertFrom-TunnelMonitorStatus 'TUNNEL_READY CONNECT only').Phase -eq 'degraded') 'no target code is not ready'
Check ((ConvertFrom-TunnelMonitorStatus 'TUNNEL_HEARTBEAT DEGRADED target_http=000 curl_exit=35').Phase -eq 'degraded') 'TLS failure heartbeat'
Check ((ConvertFrom-TunnelMonitorStatus 'TUNNEL_UNVERIFIED curl is missing').Phase -eq 'unverified') 'missing remote curl is unverified'
Check ((ConvertFrom-TunnelMonitorStatus 'TUNNEL_BIND_UNVERIFIED ss is missing').Phase -eq 'bind-warning') 'bind warning is not connectivity success'
Check ((ConvertFrom-TunnelMonitorStatus 'TUNNEL_BIND_UNSAFE port listens on 0.0.0.0').Phase -eq 'error') 'unsafe bind error'
Check ((ConvertFrom-TunnelMonitorStatus 'TUNNEL_STOPPED remote monitor ended.').Phase -eq 'stopped') 'remote monitor ended'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = Join-Path $tempRoot ('gui-status-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
    $GuiStatusPath = Join-Path $scratch 'status.json'
    $script:GuiStatusSequence = 0; $script:GuiStatusProxyUrl = ''; $script:GuiProxyHttpStatus = 0
    Write-GuiTunnelStatus 'proxy-ready' 'local only' 'http://127.0.0.1:7890' 401
    Write-GuiTunnelStatus 'connecting' 'waiting for authentication'
    $status = Get-Content -Raw -LiteralPath $GuiStatusPath -Encoding UTF8 | ConvertFrom-Json
    Check ($status.sequence -eq 2 -and $status.phase -eq 'connecting') 'atomic snapshot contains latest ordered phase'
    Check ($status.proxyUrl -eq 'http://127.0.0.1:7890' -and $status.proxyHttpStatus -eq 401) 'local proxy evidence survives short intermediate phase'
    Check ($status.httpStatus -eq 0) 'connecting has no remote HTTPS result'
    Write-GuiTunnelStatus 'degraded' 'remote rejected' '' 403
    $status = Get-Content -Raw -LiteralPath $GuiStatusPath -Encoding UTF8 | ConvertFrom-Json
    Check ($status.httpStatus -eq 403 -and $status.proxyHttpStatus -eq 401) 'local and remote HTTP observations are independent'
    Check (@(Get-ChildItem -LiteralPath $scratch -Filter '*.tmp').Count -eq 0) 'atomic writer removes own temporary files'
} finally {
    $full = [IO.Path]::GetFullPath($scratch)
    if ([IO.Path]::GetDirectoryName($full) -eq $tempRoot.TrimEnd('\')) {
        Remove-Item -LiteralPath (Join-Path $full 'status.json') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $full -ErrorAction SilentlyContinue
    }
}
Write-Host "PASS: $passed GUI status checks (no SSH login or network)"
