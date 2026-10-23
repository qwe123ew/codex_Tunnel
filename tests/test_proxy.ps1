$ErrorActionPreference = 'Stop'
$script:Passed = 0
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'ProxyTools.ps1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw 'FAIL: ProxyTools.ps1 must exist and provide the proxy discovery and probe API.'
}
. $modulePath

function Assert-True($Value, [string]$Message) {
    if (-not $Value) { throw "FAIL: $Message" }
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -cne $Actual) { throw "FAIL: $Message (expected '$Expected', actual '$Actual')" }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    & $Action
    $script:Passed++
    Write-Host "PASS: $Name"
}

Test-Case 'Bare local endpoint normalizes to HTTP' {
    Assert-Equal 'http://127.0.0.1:7890' (ConvertTo-LocalHttpProxyUrl '127.0.0.1:7890') 'Bare endpoint'
    Assert-Equal 'http://127.0.0.1:8080' (ConvertTo-LocalHttpProxyUrl ' HTTP://localhost:8080/ ') 'Localhost normalization'
    Assert-Equal 'http://[::1]:7890' (ConvertTo-LocalHttpProxyUrl '[::1]:7890') 'IPv6 loopback'
}
Test-Case 'Remote endpoints and unsafe URLs are rejected without resolving names' {
    foreach ($value in @('http://example.com:7890', 'http://192.168.1.1:7890', 'http://0.0.0.0:7890',
        'http://127.0.0.1.example.com:7890', 'http://localhost:7890@evil.example:7890',
        'http://user:secret@127.0.0.1:7890', 'http://@127.0.0.1:7890',
        'socks5://127.0.0.1:7890', 'https://127.0.0.1:7890',
        'http://127.0.0.1:7890/path', 'http://127.0.0.1:7890?x=1', 'http://127.0.0.1:7890#x',
        'http://127.0.0.1', 'http://127.0.0.1:0', 'http://127.0.0.1:65536',
        'http://127.0.0.1:7890;evil', "http://127.0.0.1:7890`n--insecure")) {
        Assert-True ($null -eq (ConvertTo-LocalHttpProxyUrl $value)) 'Unsafe endpoint must produce no candidate'
    }
}
Test-Case 'Windows per-scheme setting yields HTTP-capable loopback candidates only' {
    $candidates = @(Get-ProxyServerCandidates -ProxyServer 'http=127.0.0.1:7890;https=localhost:7891;socks=127.0.0.1:1080;ftp=example.com:2121' -Source 'Registry')
    Assert-Equal 3 $candidates.Count 'Per-scheme setting count including both localhost address families'
    Assert-Equal 'http://127.0.0.1:7890' $candidates[0].Url 'HTTP entry'
    Assert-Equal 'http://127.0.0.1:7891' $candidates[1].Url 'HTTPS means an HTTP CONNECT proxy'
    Assert-Equal 'http://[::1]:7891' $candidates[2].Url 'Localhost also includes IPv6 loopback'
    Assert-Equal 'Registry' $candidates[0].Source 'Source retained'
    Assert-Equal 7890 $candidates[0].Port 'Port is numeric'
    Assert-Equal 5 $candidates[0].Rank 'Windows configured endpoint outranks unidentified protocol ports'
}
Test-Case 'Windows single server and IPv6 server settings are accepted' {
    Assert-Equal 'http://127.0.0.1:8080' (@(Get-ProxyServerCandidates 'localhost:8080')[0].Url) 'Single server'
    Assert-Equal 'http://[::1]:8888' (@(Get-ProxyServerCandidates 'HTTPS=[::1]:8888')[0].Url) 'IPv6 server'
    Assert-Equal 0 (@(Get-ProxyServerCandidates 'socks=127.0.0.1:1080').Count) 'SOCKS-only setting is excluded'
}
Test-Case 'Candidate ordering is deterministic, deduplicated, filtered and capped' {
    $items = @()
    for ($i = 1; $i -le 30; $i++) {
        $items += [pscustomobject]@{ Url = "http://127.0.0.1:$(8000 + $i)"; Source = 'Common'; Rank = 40; ProcessName = '' }
    }
    $items += [pscustomobject]@{ Url = 'http://127.0.0.1:8001'; Source = 'KnownProcess'; Rank = 10; ProcessName = 'mihomo' }
    $items += [pscustomobject]@{ Url = 'http://example.com:8080'; Source = 'Environment'; Rank = 1; ProcessName = '' }
    $result = @(Select-ProxyCandidates $items)
    Assert-Equal 24 $result.Count 'Candidate cap'
    Assert-Equal 'KnownProcess' $result[0].Source 'Known process wins duplicate and rank'
    Assert-Equal 'mihomo' $result[0].ProcessName 'Process label retained'
    Assert-Equal 24 (@($result.Url | Select-Object -Unique).Count) 'No duplicates'
}
Test-Case 'Manual port is authoritative even when no listener exists' {
    $result = @(Get-ProxyCandidates -ManualPort 54321)
    Assert-Equal 2 $result.Count 'IPv4 and IPv6 manual candidates'
    Assert-True (@($result | Where-Object { $_.Port -ne 54321 -or $_.Source -ne 'Manual' }).Count -eq 0) 'No auto-discovered candidate leaks into manual override'
    Assert-Throws { Get-ProxyCandidates -ManualPort 65536 } 'Invalid manual port'
}
Test-Case 'Additional common port is discovered only while listening' {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 20171)
    $started = $false
    try {
        try { $listener.Start(); $started = $true } catch [Net.Sockets.SocketException] {
            if ($_.Exception.SocketErrorCode -ne [Net.Sockets.SocketError]::AddressAlreadyInUse) { throw }
        }
        $result = @(Get-ProxyCandidates)
        Assert-True (@($result | Where-Object { $_.Url -eq 'http://127.0.0.1:20171' }).Count -gt 0) 'Listening fallback port 20171 is considered'
    } finally {
        if ($started) { $listener.Stop() }
    }
}

function Test-Ipv6OnlyConfiguredDiscovery([string]$ConfigurationSource) {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::IPv6Loopback, 0)
    $listener.Server.DualMode = $false
    $savedSnapshotFunction = $null
    if (Test-Path Function:\Get-ProxySettingsSnapshot) { $savedSnapshotFunction = ${function:Get-ProxySettingsSnapshot} }
    $client = $null
    try {
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        Assert-True (@(1080, 1081, 1082, 10808, 10809, 20171, 20172, 2080, 2081, 3128, 7890, 7891, 7897, 8080, 8118, 8888, 9090) -notcontains $port) 'Fixture uses an arbitrary non-common port'
        $script:DiscoverySettingsFixture = [pscustomobject]@{ WindowsProxyEnabled = $false; WindowsProxyServer = ''; Environment = @{} }
        if ($ConfigurationSource -eq 'WindowsProxy') {
            $script:DiscoverySettingsFixture.WindowsProxyEnabled = $true
            $script:DiscoverySettingsFixture.WindowsProxyServer = ('http=localhost:{0};https=localhost:{0}' -f $port)
        } else {
            $script:DiscoverySettingsFixture.Environment['HTTP_PROXY'] = ('http://localhost:{0}' -f $port)
        }
        Set-Item -Path Function:\Get-ProxySettingsSnapshot -Value { $script:DiscoverySettingsFixture }
        $candidates = @(Get-ProxyCandidates | Where-Object { $_.Port -eq $port })
        Assert-Equal 2 $candidates.Count 'Real discovery retains both literal localhost candidates at a non-common port'
        Assert-True ($candidates.Url -contains ('http://127.0.0.1:{0}' -f $port)) 'IPv4 literal retained'
        $ipv6 = @($candidates | Where-Object { $_.Url -eq ('http://[::1]:{0}' -f $port) })
        Assert-Equal 1 $ipv6.Count 'IPv6 literal retained exactly once'
        Assert-Equal $ConfigurationSource $ipv6[0].Source 'Configured source retained through the real discovery collector'
        Assert-True (@($candidates | Where-Object { $_ -is [array] -or $_.Url -isnot [string] }).Count -eq 0) 'Candidates are flat objects'
        $client = New-Object Net.Sockets.TcpClient([Net.Sockets.AddressFamily]::InterNetworkV6)
        $connection = $client.ConnectAsync([Net.IPAddress]::IPv6Loopback, $ipv6[0].Port)
        Assert-True ($connection.Wait(1000) -and $client.Connected) 'Discovered IPv6 candidate reaches the actual IPv6-only listener'
    } finally {
        if ($null -ne $client) { $client.Dispose() }
        $listener.Stop()
        if ($null -ne $savedSnapshotFunction) {
            Set-Item -Path Function:\Get-ProxySettingsSnapshot -Value $savedSnapshotFunction
        } else {
            Remove-Item -Path Function:\Get-ProxySettingsSnapshot -ErrorAction SilentlyContinue
        }
    }
}
Test-Case 'Windows localhost settings find an IPv6-only arbitrary-port listener' {
    Test-Ipv6OnlyConfiguredDiscovery 'WindowsProxy'
}
Test-Case 'Environment localhost settings find an IPv6-only arbitrary-port listener' {
    Test-Ipv6OnlyConfiguredDiscovery 'Environment:HTTP_PROXY'
}

$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('Codex proxy tests ' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($testDirectory)
$nativeFixture = Join-Path $testDirectory 'argument fixture.ps1'
$realCurl = (Get-Command 'curl.exe' -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$nativePowerShell = (Get-Command 'powershell.exe' -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$realInvokeProxyProcess = ${function:Invoke-ProxyProcess}
try {
    # Native quoting/watchdog checks use the installed Microsoft executable.
    # Network result fixtures replace only the external process boundary below.
    [IO.File]::WriteAllText($nativeFixture, 'param([string]$Value,[string]$Quoted,[string]$Trailing); @($Value,$Quoted,$Trailing) | ConvertTo-Json -Compress')
    Test-Case 'PS5 native argv preserves spaces, quotes and trailing backslashes' {
        $result = Invoke-ProxyProcess -FileName $nativePowerShell -Arguments @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $nativeFixture, '-Value', 'path with spaces', '-Quoted', 'a"b', '-Trailing', 'C:\directory with spaces\') -TimeoutSeconds 5
        Assert-Equal 0 $result.ExitCode 'Installed PowerShell executed fixture path with spaces'
        $nativeValues = ConvertFrom-Json -InputObject $result.Output
        Assert-Equal 'path with spaces' $nativeValues[0] 'Spaces preserved'
        Assert-Equal 'a"b' $nativeValues[1] 'Quote preserved'
        Assert-Equal 'C:\directory with spaces\' $nativeValues[2] 'Trailing backslash preserved'
    }
    Test-Case 'Watchdog terminates its own stuck native process' {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-ProxyProcess -FileName $nativePowerShell -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30') -TimeoutSeconds 1
        $timer.Stop()
        Assert-True $result.TimedOut 'Native watchdog reports timeout'
        Assert-Equal 124 $result.ExitCode 'Native watchdog exit code'
        Assert-True ($timer.Elapsed.TotalSeconds -lt 5) 'Native watchdog terminates promptly'
    }
    Set-Item -Path Function:\Invoke-ProxyProcess -Value {
        param([string]$FileName, [string[]]$Arguments, [int]$TimeoutSeconds)
        $script:CapturedArguments = $Arguments
        $script:CapturedTimeout = $TimeoutSeconds
        $output = '__CODEX_PROXY__401|200'
        $exitCode = 0
        $timedOut = $false
        switch ($script:FixtureMode) {
            'tls' { $output = '__CODEX_PROXY__000|200'; $exitCode = 35 }
            'certificate' { $output = '__CODEX_PROXY__000|200'; $exitCode = 60 }
            'timeout' { $output = '__CODEX_PROXY__000|200'; $exitCode = 28 }
            'hang' { $output = ''; $exitCode = 124; $timedOut = $true }
            'invalid' { $output = 'HTTP/1.1 200 Connection established' }
            '500' { $output = '__CODEX_PROXY__500|200' }
            '403' { $output = '__CODEX_PROXY__403|200' }
            '200' { $output = '__CODEX_PROXY__200|200' }
        }
        [pscustomobject]@{ ExitCode = $exitCode; Output = $output; TimedOut = $timedOut }
    }
    Test-Case '401 is a successful unauthenticated HTTPS route probe' {
        $script:FixtureMode = '401'
        $result = Test-HttpProxy -ProxyUrl 'http://127.0.0.1:7890' -CurlPath $realCurl -TimeoutSeconds 8
        Assert-True $result.Success '401 indicates target TLS and HTTP were reached'
        Assert-Equal 401 $result.StatusCode 'Final status code'
        Assert-Equal 200 $result.ConnectCode 'CONNECT status code'
        Assert-Equal 0 $result.ExitCode 'Curl exit code'
        Assert-Equal 'http://127.0.0.1:7890' $result.ProxyUrl 'Proxy URL returned'
        $nativeArguments = $script:CapturedArguments
        Assert-Equal 10 $script:CapturedTimeout 'Independent watchdog permits curl to return its own timeout first'
        Assert-Equal '-q' $nativeArguments[0] 'Disable user curl config before other arguments'
        Assert-True ($nativeArguments -contains 'https://api.openai.com/v1/models') 'Exact HTTPS target'
        Assert-True ($nativeArguments -contains 'GET') 'Real GET request'
        Assert-True ($nativeArguments -contains 'localhost') 'Nonempty no-proxy value survives PowerShell 5.1 argv'
        foreach ($pair in @(@('--proxy', 'http://127.0.0.1:7890'), @('--noproxy', 'localhost'), @('--connect-timeout', '8'), @('--max-time', '8'), @('--output', 'NUL'))) {
            $index = [Array]::IndexOf($nativeArguments, $pair[0])
            Assert-True ($index -ge 0 -and $nativeArguments[$index + 1] -ceq $pair[1]) ('Native option/value pair: ' + $pair[0])
        }
        Assert-True (-not ($nativeArguments -contains '-k') -and -not ($nativeArguments -contains '--insecure') -and -not ($nativeArguments -contains '--ssl-no-revoke')) 'Certificate checks remain enabled'
    }
    Test-Case '2xx response passes' {
        $script:FixtureMode = '200'
        Assert-True (Test-HttpProxy -ProxyUrl 'http://[::1]:7890' -CurlPath $realCurl).Success '2xx accepted'
    }
    Test-Case '403 proves reachability but is rejected as unusable' {
        $script:FixtureMode = '403'
        $result = Test-HttpProxy -ProxyUrl 'http://127.0.0.1:7890' -CurlPath $realCurl
        Assert-True (-not $result.Success) '403 rejected'
        Assert-Equal 403 $result.StatusCode '403 retained'
        Assert-True ($result.Message -match '(?i)reject|forbidden') 'Honest rejection message'
    }
    Test-Case 'CONNECT 200 never hides TLS, certificate or timeout failure' {
        foreach ($mode in @('tls', 'certificate', 'timeout')) {
            $script:FixtureMode = $mode
            $result = Test-HttpProxy -ProxyUrl 'http://127.0.0.1:7890' -CurlPath $realCurl
            Assert-True (-not $result.Success) "CONNECT-only false positive: $mode"
            Assert-Equal 200 $result.ConnectCode 'CONNECT retained for diagnosis'
            Assert-True ($result.ExitCode -ne 0) 'Curl failure retained'
        }
    }
    Test-Case 'Malformed output and server errors do not pass' {
        foreach ($mode in @('invalid', '500')) {
            $script:FixtureMode = $mode
            Assert-True (-not (Test-HttpProxy -ProxyUrl 'http://127.0.0.1:7890' -CurlPath $realCurl).Success) 'No false success'
        }
    }
    Test-Case 'Probe maps watchdog timeout to a controlled failure' {
        $script:FixtureMode = 'hang'
        $result = Test-HttpProxy -ProxyUrl 'http://127.0.0.1:7890' -CurlPath $realCurl -TimeoutSeconds 1
        Assert-True (-not $result.Success) 'Stuck process fails'
        Assert-Equal 124 $result.ExitCode 'Watchdog exit code'
    }
    Test-Case 'Invalid probe inputs are refused before launching a process' {
        Assert-Throws { Test-HttpProxy -ProxyUrl 'http://evil.example:7890' -CurlPath $realCurl } 'Remote proxy rejected'
        Assert-Throws { Test-HttpProxy -ProxyUrl 'http://127.0.0.1:7890' -CurlPath $realCurl -TimeoutSeconds 0 } 'Zero timeout rejected'
        Assert-Throws { Test-HttpProxy -ProxyUrl 'http://127.0.0.1:7890' -CurlPath $realCurl -TimeoutSeconds 61 } 'Excessive timeout rejected'
    }
} finally {
    Set-Item -Path Function:\Invoke-ProxyProcess -Value $realInvokeProxyProcess
    $resolvedTestDirectory = [System.IO.Path]::GetFullPath($testDirectory)
    $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedTestDirectory.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing cleanup outside the temporary directory.'
    }
    Remove-Item -LiteralPath $resolvedTestDirectory -Recurse -Force
}
Write-Host "Proxy tests: $script:Passed passed (PowerShell $($PSVersionTable.PSVersion))."
