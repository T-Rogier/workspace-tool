param(
    [string]$InstallDir = "$HOME\.ws"
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# Windows PowerShell 5.1 treats UTF-8 files without a BOM as ANSI.  Re-encode
# installed text files with a BOM so non-ASCII characters in ws.ps1 remain
# valid PowerShell syntax regardless of the active Windows code page.
$utf8WithBom = New-Object System.Text.UTF8Encoding($true)
$scriptSource = Join-Path $PSScriptRoot "ws.ps1"
$scriptDestination = Join-Path $InstallDir "ws.ps1"
$scriptContent = [System.IO.File]::ReadAllText($scriptSource)
[System.IO.File]::WriteAllText($scriptDestination, $scriptContent, $utf8WithBom)

$scriptsSource = Join-Path $PSScriptRoot "scripts"
if (Test-Path $scriptsSource) {
    $scriptsDestination = Join-Path $InstallDir "scripts"
    New-Item -ItemType Directory -Path $scriptsDestination -Force | Out-Null
    Copy-Item -Path (Join-Path $scriptsSource "*") -Destination $scriptsDestination -Force
}

$configDestination = Join-Path $InstallDir "config.json"
if (-not (Test-Path $configDestination)) {
    $legacyConfigPath = Join-Path $InstallDir "repos.json"
    if (Test-Path $legacyConfigPath) {
        Move-Item -LiteralPath $legacyConfigPath -Destination $configDestination
        Write-Host "Configuration existante migree vers config.json." -ForegroundColor Green
    }
    else {
        $configSource = Join-Path $PSScriptRoot "config.json"
        $configContent = [System.IO.File]::ReadAllText($configSource)
        [System.IO.File]::WriteAllText($configDestination, $configContent, $utf8WithBom)
    }
}

$profileDir = Split-Path -Parent $PROFILE
if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}

if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$functionBlock = @"

function ws {
    & "$InstallDir\ws.ps1" @args
}
"@

$currentProfile = Get-Content $PROFILE -Raw
if ($null -eq $currentProfile) {
    $currentProfile = ""
}

if ($currentProfile -notmatch 'function\s+ws\s*\{') {
    Add-Content $PROFILE $functionBlock
    Write-Host "Fonction 'ws' ajoutee a ton profil PowerShell." -ForegroundColor Green
}
else {
    Write-Host "Une fonction 'ws' existe deja dans ton profil PowerShell." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Installation terminee." -ForegroundColor Green
Write-Host "Configuration : $(Join-Path $InstallDir 'config.json')"
Write-Host ""
Write-Host "Recharge ton profil avec :"
Write-Host "  . `$PROFILE"
Write-Host ""
Write-Host "Puis teste :"
Write-Host "  ws list"
