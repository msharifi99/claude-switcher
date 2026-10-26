#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeSwitcher.Core.psm1') -Force -PassThru -DisableNameChecking
$root = Join-Path ([IO.Path]::GetTempPath()) ('claude-discovery-test-' + [Guid]::NewGuid().ToString('N'))
$originalAppData = $env:APPDATA
$originalLocalAppData = $env:LOCALAPPDATA
$script:checks = 0
function Assert { param([bool]$Ok,[string]$Message) if (-not $Ok) { throw "FAILED: $Message" }; $script:checks++; Write-Host "PASS $Message" }
function New-Profile {
    param([string]$Path)
    [IO.Directory]::CreateDirectory((Join-Path $Path 'Network')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $Path 'config.json'),'{}')
    [IO.File]::WriteAllText((Join-Path $Path 'Network\Cookies'),'fake-cookie-database')
    $Path
}
function New-Environment {
    param([string]$Name)
    $env:APPDATA = Join-Path $root ($Name + '\Roaming')
    $env:LOCALAPPDATA = Join-Path $root ($Name + '\Local')
    [IO.Directory]::CreateDirectory($env:APPDATA) | Out-Null
    [IO.Directory]::CreateDirectory($env:LOCALAPPDATA) | Out-Null
}
function Assert-Ambiguous {
    param([string]$Message)
    $rejected = $false
    try { $null = New-SwitcherContext } catch { $rejected = $_.Exception.Message -like 'Could not identify one Claude Desktop profile*' }
    Assert $rejected $Message
}
try {
    New-Environment 'local-data'
    $localData = New-Profile (Join-Path $env:LOCALAPPDATA 'Claude-Data\claude_testpackage')
    Assert ((New-SwitcherContext).DataDirectory -eq $localData) 'Local Claude-Data package profile is detected automatically'
    Assert ((New-SwitcherContext).CookiePath -eq (Join-Path $localData 'Network\Cookies')) 'Detected local profile supplies its cookie database path'
    [IO.Directory]::CreateDirectory((Join-Path $env:LOCALAPPDATA 'Claude-Data\claude_empty')) | Out-Null
    $null = New-Profile (Join-Path $env:LOCALAPPDATA 'Claude-Data\unrelated')
    Assert ((New-SwitcherContext).DataDirectory -eq $localData) 'Empty package folders and unrelated Claude-Data children are ignored'
    $null = New-Profile (Join-Path $env:LOCALAPPDATA 'Claude-Data\claude_secondpackage')
    Assert-Ambiguous 'Multiple local package profiles require an explicit selection'
    Assert ((New-SwitcherContext -DesktopDataDirectory $localData).DataDirectory -eq $localData) 'Explicit profile selection bypasses ambiguous automatic detection'

    New-Environment 'local-standard'
    $localStandard = New-Profile (Join-Path $env:LOCALAPPDATA 'Claude')
    Assert ((New-SwitcherContext).DataDirectory -eq $localStandard) 'Direct Local Claude profile is detected automatically'

    New-Environment 'roaming'
    $roaming = New-Profile (Join-Path $env:APPDATA 'Claude')
    Assert ((New-SwitcherContext).DataDirectory -eq $roaming) 'Existing Roaming profile detection is preserved'
    $null = New-Profile (Join-Path $env:LOCALAPPDATA 'Claude-Data\claude_testpackage')
    Assert-Ambiguous 'Roaming and local profiles together require an explicit selection'

    New-Environment 'store'
    $store = New-Profile (Join-Path $env:LOCALAPPDATA 'Packages\Claude_testpackage\LocalCache\Roaming\Claude')
    Assert ((New-SwitcherContext).DataDirectory -eq $store) 'Existing Microsoft Store profile detection is preserved'
    $null = New-Profile (Join-Path $env:LOCALAPPDATA 'Claude-Data\claude_testpackage')
    Assert-Ambiguous 'Store and local profiles together require an explicit selection'

    New-Environment 'missing'
    Assert-Ambiguous 'Missing profiles retain the explicit-path error'
    Write-Host "All $script:checks discovery checks passed using temporary fake data only."
} finally {
    $env:APPDATA = $originalAppData
    $env:LOCALAPPDATA = $originalLocalAppData
    Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($root)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -match '^claude-discovery-test-[a-f0-9]{32}$') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
