[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw "The preinstalled .NET Framework C# compiler is missing: $compiler"
}

$source = Join-Path $PSScriptRoot 'Program.cs'
$manifest = Join-Path $PSScriptRoot 'app.manifest'
$resourceNames = @('Start-Tunnel.ps1', 'TunnelTools.ps1', 'ProxyTools.ps1', 'SshImport.ps1', 'remote-monitor.sh', 'read.md')
foreach ($required in @($source, $manifest) + @($resourceNames | ForEach-Object { Join-Path $projectRoot $_ })) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing build input: $required" }
}

$outputDirectory = Join-Path $projectRoot 'dist'
[void][IO.Directory]::CreateDirectory($outputDirectory)
$outputFile = Join-Path $outputDirectory 'CodexProxyTunnel.exe'
$compilerArguments = @(
    '/nologo', '/target:exe', '/platform:anycpu', '/optimize+', '/debug-', '/utf8output', '/warn:4', '/warnaserror+'
    ('/out:' + $outputFile)
    ('/win32manifest:' + $manifest)
)
foreach ($name in $resourceNames) {
    $compilerArguments += '/resource:' + (Join-Path $projectRoot $name) + ',CodexProxyTunnel.Runtime.' + $name
}
$compilerArguments += $source

# Uses the Windows-supplied compiler only: no SDK, NuGet, network or new runtime.
& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0) { throw "C# compilation failed with exit code $LASTEXITCODE." }
$built = Get-Item -LiteralPath $outputFile
Write-Host ('Built {0} ({1:N0} bytes), version {2}' -f $built.FullName, $built.Length, $built.VersionInfo.FileVersion)
Write-Output $built.FullName
