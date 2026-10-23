[CmdletBinding()]
param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw "The preinstalled .NET Framework C# compiler is missing: $compiler"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $projectRoot 'dist\gui' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$outputFile = Join-Path $OutputDirectory 'CodexTunnel.exe'
$sources = @('GuiApp.cs', 'ServerEditorWindow.cs', 'TunnelBackend.cs', 'ServerCatalog.cs') | ForEach-Object { Join-Path $PSScriptRoot $_ }
$manifest = Join-Path $PSScriptRoot 'app.manifest'
$icon = Join-Path $PSScriptRoot 'assets\app.ico'
# Explicit public-runtime allowlist. No settings, SSH profiles, logs or credentials are embedded.
$resources = @(
    @{ Path = (Join-Path $projectRoot 'Start-Tunnel.ps1'); Name = 'Start-Tunnel.ps1' }
    @{ Path = (Join-Path $projectRoot 'TunnelTools.ps1'); Name = 'TunnelTools.ps1' }
    @{ Path = (Join-Path $projectRoot 'ProxyTools.ps1'); Name = 'ProxyTools.ps1' }
    @{ Path = (Join-Path $projectRoot 'SshImport.ps1'); Name = 'SshImport.ps1' }
    @{ Path = (Join-Path $projectRoot 'remote-monitor.sh'); Name = 'remote-monitor.sh' }
    @{ Path = (Join-Path $projectRoot 'remote-vscode-config.sh'); Name = 'remote-vscode-config.sh' }
    @{ Path = (Join-Path $projectRoot 'remote-vscode-config.js'); Name = 'remote-vscode-config.js' }
    @{ Path = (Join-Path $projectRoot 'read.md'); Name = 'read.md' }
    @{ Path = (Join-Path $PSScriptRoot 'Gui-Api.ps1'); Name = 'Gui-Api.ps1' }
)
$references = @(
    (Join-Path $framework 'WPF\PresentationFramework.dll')
    (Join-Path $framework 'WPF\PresentationCore.dll')
    (Join-Path $framework 'WPF\WindowsBase.dll')
    (Join-Path $framework 'System.Xaml.dll')
    (Join-Path $framework 'System.Web.Extensions.dll')
)
foreach ($required in $sources + @($manifest, $icon) + $references + @($resources | ForEach-Object { $_.Path })) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing build input: $required" }
}
$compilerArguments = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', '/debug-', '/utf8output', '/warn:4', '/warnaserror+'
    ('/out:' + $outputFile), ('/win32manifest:' + $manifest), ('/win32icon:' + $icon)
    ('/resource:' + $icon + ',CodexTunnelGui.Brand.app.ico')
)
foreach ($reference in $references) { $compilerArguments += '/reference:' + $reference }
foreach ($resource in $resources) { $compilerArguments += '/resource:' + $resource.Path + ',CodexTunnelGui.Runtime.' + $resource.Name }
$compilerArguments += $sources
# Windows-supplied compiler and WPF only. No SDK, NuGet or network download.
& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0) { throw "C# compilation failed with exit code $LASTEXITCODE." }
$built = Get-Item -LiteralPath $outputFile
Write-Host ('Built GUI {0} ({1:N0} bytes), version {2}' -f $built.FullName, $built.Length, $built.VersionInfo.FileVersion)
Write-Output $built.FullName
