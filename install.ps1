param(
    [string]$InstallDir = "$HOME\.ws"
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

Copy-Item "$PSScriptRoot\ws.ps1" (Join-Path $InstallDir "ws.ps1") -Force
Copy-Item "$PSScriptRoot\repos.json" (Join-Path $InstallDir "repos.json") -Force

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

if ($currentProfile -notmatch 'function\s+ws\s*\{') {
    Add-Content $PROFILE $functionBlock
    Write-Host "Fonction 'ws' ajoutée à ton profil PowerShell." -ForegroundColor Green
}
else {
    Write-Host "Une fonction 'ws' existe déjà dans ton profil PowerShell." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Installation terminée." -ForegroundColor Green
Write-Host "Configuration : $(Join-Path $InstallDir 'repos.json')"
Write-Host ""
Write-Host "Recharge ton profil avec :"
Write-Host "  . `$PROFILE"
Write-Host ""
Write-Host "Puis teste :"
Write-Host "  ws list"
