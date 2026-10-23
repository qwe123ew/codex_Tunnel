# Windows PowerShell 5.1 compatible. Discovery is read-only; no settings are changed.

function ConvertTo-LocalHttpProxyUrl {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $valueText = $Value.Trim()
    # A strict allowlist avoids DNS, URI parser aliases, credentials and option injection.
    if ($valueText -notmatch '(?i)^(?:http://)?(?<host>localhost|127\.0\.0\.1|\[::1\]):(?<port>[0-9]{1,5})/?$') {
        return $null
    }
    $portNumber = [int]$Matches['port']
    if ($portNumber -lt 1 -or $portNumber -gt 65535) { return $null }
    $proxyHost = '127.0.0.1'
    if ($Matches['host'] -eq '[::1]') { $proxyHost = '[::1]' }
    return ('http://{0}:{1}' -f $proxyHost, $portNumber)
}

function New-ProxyCandidate {
    param([string]$Url, [string]$Source, [int]$Rank = 50, [string]$ProcessName = '')
    $normalized = ConvertTo-LocalHttpProxyUrl $Url
    if (-not $normalized) { return }
    $portNumber = ([uri]$normalized).Port
    $literalUrls = @($normalized)
    # localhost may name an IPv4-only or IPv6-only listener. Keep both literal
    # candidates and let the bounded HTTPS probes select the working family.
    if ($Url.Trim() -match '(?i)^(?:http://)?localhost:') {
        $literalUrls += ('http://[::1]:{0}' -f $portNumber)
    }
    foreach ($literalUrl in $literalUrls) {
        [pscustomobject]@{
            Url = $literalUrl
            Source = $Source
            Port = $portNumber
            ProcessName = $ProcessName
            Rank = $Rank
        }
    }
}

function Get-ProxyServerCandidates {
    param([AllowNull()][AllowEmptyString()][string]$ProxyServer, [string]$Source = 'WindowsProxy')
    if ([string]::IsNullOrWhiteSpace($ProxyServer)) { return }
    foreach ($entry in ($ProxyServer -split ';')) {
        $serverValue = $entry.Trim()
        if ($serverValue.Contains('=')) {
            # In Windows proxy settings, https= also names an HTTP CONNECT proxy.
            # socks= is deliberately excluded: this launcher forwards HTTP/mixed proxies.
            if ($serverValue -notmatch '(?i)^(?:http|https)\s*=\s*(.+)$') { continue }
            $serverValue = $Matches[1].Trim()
        }
        New-ProxyCandidate -Url $serverValue -Source $Source -Rank 5
    }
}

function Select-ProxyCandidates {
    param([AllowEmptyCollection()][object[]]$Candidates)
    $valid = @(
        foreach ($candidate in $Candidates) {
            if ($null -eq $candidate) { continue }
            $rank = 50
            if ($null -ne $candidate.PSObject.Properties['Rank']) { $rank = [int]$candidate.Rank }
            $processName = ''
            if ($null -ne $candidate.PSObject.Properties['ProcessName']) { $processName = [string]$candidate.ProcessName }
            New-ProxyCandidate -Url ([string]$candidate.Url) -Source ([string]$candidate.Source) -Rank $rank -ProcessName $processName
        }
    )
    $seen = @{}
    $count = 0
    foreach ($candidate in ($valid | Sort-Object Rank, Port, Url, Source)) {
        if ($seen.ContainsKey($candidate.Url)) { continue }
        $seen[$candidate.Url] = $true
        [pscustomobject]@{
            Url = $candidate.Url
            Source = $candidate.Source
            Port = [int]$candidate.Port
            ProcessName = $candidate.ProcessName
        }
        $count++
        if ($count -ge 24) { break }
    }
}

function Join-ProxyProcessArguments {
    param([string[]]$Arguments)
    # ProcessStartInfo.Arguments uses the Windows CommandLineToArgvW convention.
    # Quote each argument explicitly, including values containing spaces.
    $quoted = foreach ($argument in $Arguments) {
        $escaped = [regex]::Replace($argument, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        '"' + $escaped + '"'
    }
    return ($quoted -join ' ')
}

function Invoke-ProxyProcess {
    param([string]$FileName, [string[]]$Arguments, [ValidateRange(1, 65)][int]$TimeoutSeconds)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = $FileName
    $process.StartInfo.Arguments = Join-ProxyProcessArguments $Arguments
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        if (-not $process.Start()) { throw 'Process did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Only this newly-created child is killed; existing proxy/SSH processes are untouched.
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit(1000)
            return [pscustomobject]@{ ExitCode = 124; Output = ''; TimedOut = $true }
        }
        [void]$stdoutTask.Wait(250)
        [void]$stderrTask.Wait(250)
        $outputText = ''
        if ($stdoutTask.IsCompleted -and -not $stdoutTask.IsFaulted) { $outputText = $stdoutTask.Result }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outputText; TimedOut = $false }
    } catch {
        # Do not surface arbitrary child stderr, credentials, environment or command text.
        return [pscustomobject]@{ ExitCode = -1; Output = ''; TimedOut = $false }
    } finally {
        $process.Dispose()
    }
}

function Get-ProxySettingsSnapshot {
    # Keep the OS configuration read boundary separate from candidate discovery.
    # The snapshot is never logged and may contain rejected credential-bearing values.
    $windowsEnabled = $false
    $windowsServer = ''
    try {
        $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($settings.ProxyEnable -eq 1) {
            $windowsEnabled = $true
            $windowsServer = [string]$settings.ProxyServer
        }
    } catch { }
    $environmentValues = @{}
    foreach ($variable in @('HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY')) {
        $environmentValues[$variable] = [Environment]::GetEnvironmentVariable($variable, 'Process')
    }
    [pscustomobject]@{
        WindowsProxyEnabled = $windowsEnabled
        WindowsProxyServer = $windowsServer
        Environment = $environmentValues
    }
}

function Get-ProxyCandidates {
    param([ValidateRange(0, 65535)][int]$ManualPort = 0)
    if ($ManualPort -gt 0) {
        $manual = @(
            New-ProxyCandidate -Url ('http://127.0.0.1:{0}' -f $ManualPort) -Source 'Manual' -Rank 0
            New-ProxyCandidate -Url ('http://[::1]:{0}' -f $ManualPort) -Source 'Manual' -Rank 0
        )
        Select-ProxyCandidates $manual
        return
    }

    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $settings = Get-ProxySettingsSnapshot
    if ($settings.WindowsProxyEnabled) {
        foreach ($candidate in @(Get-ProxyServerCandidates -ProxyServer $settings.WindowsProxyServer -Source 'WindowsProxy')) {
            $candidates.Add($candidate)
        }
    }
    foreach ($variable in @('HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY')) {
        $value = $settings.Environment[$variable]
        foreach ($candidate in @(New-ProxyCandidate -Url $value -Source ('Environment:' + $variable) -Rank 30)) {
            $candidates.Add($candidate)
        }
    }

    $knownProcesses = @{}
    try {
        foreach ($proxyProcess in (Get-Process -ErrorAction SilentlyContinue)) {
            if ($proxyProcess.ProcessName -match '(?i)^(v2ray|v2rayN|xray|mihomo|clash(?:-win64|-meta|-core)?|sing-box|sslocal|ss-local|ssr-local|shadowsocks|shadowsocksr|hysteria2?|tuic-client|nekoray|nekobox)$') {
                $knownProcesses[[string]$proxyProcess.Id] = $proxyProcess.ProcessName
            }
        }
    } catch { }
    if ($knownProcesses.Count -gt 0) {
        $netstat = Get-Command -Name 'netstat.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $netstat) {
            $snapshot = Invoke-ProxyProcess -FileName $netstat.Source -Arguments @('-ano', '-p', 'tcp') -TimeoutSeconds 5
            if ($snapshot.ExitCode -eq 0) {
                foreach ($line in ($snapshot.Output -split '\r?\n')) {
                    if ($line -notmatch '^\s*TCP\s+(?<endpoint>\S+)\s+\S+\s+LISTENING\s+(?<owner>\d+)\s*$') { continue }
                    $ownerId = $Matches['owner']
                    $endpoint = $Matches['endpoint']
                    if (-not $knownProcesses.ContainsKey($ownerId)) { continue }
                    # Wildcard listeners are contacted only through the local loopback address.
                    $endpoint = $endpoint -replace '^0\.0\.0\.0:', '127.0.0.1:' -replace '^\[::\]:', '[::1]:'
                    foreach ($candidate in @(New-ProxyCandidate -Url $endpoint -Source 'KnownProcess' -Rank 10 -ProcessName $knownProcesses[$ownerId])) {
                        $candidates.Add($candidate)
                    }
                }
            }
        }
    }

    # Common fallback ports are considered only when an active local TCP listener exists.
    $commonPorts = @(1080, 1081, 1082, 10808, 10809, 20171, 20172, 2080, 2081, 3128, 7890, 7891, 7897, 8080, 8118, 8888, 9090)
    try {
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        foreach ($listener in $listeners) {
            if ($commonPorts -notcontains $listener.Port) { continue }
            $listenerHost = $listener.Address.ToString()
            if ($listenerHost -eq '0.0.0.0') { $listenerHost = '127.0.0.1' }
            if ($listenerHost -eq '::' -or $listenerHost -eq '::1') { $listenerHost = '[::1]' }
            foreach ($candidate in @(New-ProxyCandidate -Url ('{0}:{1}' -f $listenerHost, $listener.Port) -Source 'CommonListeningPort' -Rank 40)) {
                $candidates.Add($candidate)
            }
        }
    } catch { }
    Select-ProxyCandidates -Candidates $candidates.ToArray()
}

function Test-HttpProxy {
    param(
        [Parameter(Mandatory = $true)][string]$ProxyUrl,
        [Parameter(Mandatory = $true)][string]$CurlPath,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 8
    )
    $normalized = ConvertTo-LocalHttpProxyUrl $ProxyUrl
    if (-not $normalized) { throw 'ProxyUrl must be a local HTTP proxy with an explicit port and no credentials.' }
    $curlCommand = Get-Command -Name $CurlPath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $curlCommand) { throw 'The specified curl executable was not found.' }
    # -q must be first to disable .curlrc. --noproxy localhost overrides inherited
    # NO_PROXY without an empty argument (which Windows PowerShell 5.1 loses).
    # No API key is sent. An expected unauthenticated 401 proves target HTTPS access.
    $arguments = @(
        '-q', '--silent', '--show-error', '--request', 'GET',
        '--proxy', $normalized, '--noproxy', 'localhost',
        '--connect-timeout', [string]$TimeoutSeconds, '--max-time', [string]$TimeoutSeconds,
        '--output', 'NUL', '--write-out', '__CODEX_PROXY__%{http_code}|%{http_connect}',
        '--url', 'https://api.openai.com/v1/models'
    )
    # The extra two seconds allow curl to return its own timeout diagnosis first.
    $probe = Invoke-ProxyProcess -FileName $curlCommand.Source -Arguments $arguments -TimeoutSeconds ($TimeoutSeconds + 2)
    $statusCode = 0
    $connectCode = 0
    $validOutput = $probe.Output -match '^__CODEX_PROXY__(\d{3})\|(\d{3})\s*$'
    if ($validOutput) {
        $statusCode = [int]$Matches[1]
        $connectCode = [int]$Matches[2]
    }
    $success = $probe.ExitCode -eq 0 -and $validOutput -and ($statusCode -eq 401 -or ($statusCode -ge 200 -and $statusCode -le 299))
    $message = 'No valid target HTTPS response was received.'
    if ($success) {
        if ($statusCode -eq 401) { $message = 'Target HTTPS reached; HTTP 401 is the expected unauthenticated response.' }
        else { $message = 'Target HTTPS reached with a successful HTTP response.' }
    } elseif ($probe.TimedOut) {
        $message = 'Probe watchdog timeout; the probe process was terminated.'
    } elseif ($probe.ExitCode -eq -1) {
        $message = 'The probe process could not be executed.'
    } elseif ($probe.ExitCode -ne 0) {
        if ($connectCode -eq 200) {
            $message = 'HTTP CONNECT succeeded, but the target HTTPS/TLS request failed (curl exit {0}).' -f $probe.ExitCode
        } else {
            $message = 'Proxy or target HTTPS connection failed (curl exit {0}, CONNECT {1}).' -f $probe.ExitCode, $connectCode
        }
    } elseif ($statusCode -eq 403) {
        $message = 'Target HTTPS reached, but HTTP 403 rejected the request; this route is not usable.'
    } elseif ($statusCode -gt 0) {
        $message = 'Target returned HTTP {0}; this route is not accepted as usable.' -f $statusCode
    }
    [pscustomobject]@{
        Success = [bool]$success
        StatusCode = [int]$statusCode
        ConnectCode = [int]$connectCode
        ExitCode = [int]$probe.ExitCode
        ProxyUrl = $normalized
        Message = $message
    }
}
