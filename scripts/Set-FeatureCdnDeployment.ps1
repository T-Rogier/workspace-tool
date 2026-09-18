param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$relativeConfigPath = "tools\deploy-cdn-local.local.json"
$configPath = Join-Path $RepositoryPath $relativeConfigPath

if ($Remove) {
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Remove-Item -LiteralPath $configPath -Force
    }

    Write-Host "Configuration de deploiement CDN supprimee : $relativeConfigPath" -ForegroundColor Green
    return
}

$destination = Join-Path (Join-Path "C:\inetpub\wwwroot" $WorkspaceName) "dev-cdn"
$configuration = [pscustomobject]@{ destination = $destination }
$content = $configuration | ConvertTo-Json
[System.IO.File]::WriteAllText($configPath, $content, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Destination CDN de la feature definie : $destination" -ForegroundColor Green
