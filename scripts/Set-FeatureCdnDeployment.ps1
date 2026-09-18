param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [string]$LocalRepositoryPath,

    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Copy-RootEnvironmentFiles {
    param([string]$SourceRepositoryPath, [string]$TargetRepositoryPath)

    $sourceComponentsPath = Join-Path $SourceRepositoryPath "components"
    $targetComponentsPath = Join-Path $TargetRepositoryPath "components"
    if (-not (Test-Path -LiteralPath $sourceComponentsPath -PathType Container)) {
        throw "Dossier d'environnements local introuvable : $sourceComponentsPath"
    }
    $environmentFiles = @(
        Get-ChildItem -LiteralPath $sourceComponentsPath -File -Filter ".env.*" |
            Where-Object { $_.Name -notlike "*.example" }
    )

    foreach ($environmentFile in $environmentFiles) {
        Copy-Item -LiteralPath $environmentFile.FullName -Destination (Join-Path $targetComponentsPath $environmentFile.Name) -Force
        $environment = $environmentFile.Name.Substring(".env.".Length)

        Push-Location $TargetRepositoryPath
        try {
            & pnpm env:generate -- $environment
            if ($LASTEXITCODE -ne 0) {
                throw "La generation des environnements a echoue pour : $environment"
            }
        }
        finally {
            Pop-Location
        }

        Write-Host "Environnement copie et genere : components\\$($environmentFile.Name)" -ForegroundColor Green
    }
}

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

if ([string]::IsNullOrWhiteSpace($LocalRepositoryPath)) {
    throw "Le parametre -LocalRepositoryPath est requis pour copier les environnements locaux."
}

Copy-RootEnvironmentFiles -SourceRepositoryPath $LocalRepositoryPath -TargetRepositoryPath $RepositoryPath
