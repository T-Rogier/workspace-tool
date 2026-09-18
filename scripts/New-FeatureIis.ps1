param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceConfig,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryName,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-Property {
    param($Object, [string]$Name)
    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name)
}

function Expand-Template {
    param([string]$Value, $Variables)
    foreach ($property in $Variables.PSObject.Properties) {
        $Value = $Value.Replace("{$($property.Name)}", [string]$property.Value)
    }
    return $Value
}

function Set-PublishUrl {
    param([string]$ProfilePath, [string]$TargetPath)
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($ProfilePath)
    $publishUrl = $xml.SelectSingleNode("//*[local-name()='PublishUrl' or local-name()='publishUrl']")
    if (-not $publishUrl) {
        $propertyGroup = $xml.SelectSingleNode("//*[local-name()='PropertyGroup']")
        if (-not $propertyGroup) { throw "PropertyGroup introuvable dans : $ProfilePath" }
        $publishUrl = $xml.CreateElement("PublishUrl", $xml.DocumentElement.NamespaceURI)
        $null = $propertyGroup.AppendChild($publishUrl)
    }
    $publishUrl.InnerText = [System.IO.Path]::GetFullPath($TargetPath)
    $xml.Save($ProfilePath)
}

function Get-SuffixedPath {
    param([string]$Path, [string]$Suffix)
    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
    $parent = Split-Path -Parent $expandedPath
    $leaf = Split-Path -Leaf $expandedPath
    if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($leaf)) { throw "Chemin physique IIS invalide : $Path" }
    return (Join-Path (Join-Path $parent $Suffix) $leaf)
}

function Get-SuffixedHostName {
    param([string]$HostName, [string]$Suffix)
    if ([string]::IsNullOrWhiteSpace($HostName)) { return $HostName }
    $labels = $HostName.Split('.', 2)
    if ($labels.Count -eq 1) { return "$HostName-$Suffix" }
    return "$($labels[0])-$Suffix.$($labels[1])"
}

function Get-SiteElement {
    param([System.Xml.XmlDocument]$Document, [string]$SiteName)
    foreach ($site in @($Document.SelectNodes("/configuration/system.applicationHost/sites/site"))) {
        if ($site.GetAttribute("name") -eq $SiteName) { return $site }
    }
    return $null
}

function Copy-TemplateIisSite {
    param([string]$TemplateSite, [string]$TargetSite, [string]$Suffix)
    $applicationHostPath = Join-Path $env:windir "System32\inetsrv\config\applicationHost.config"
    $originalContent = [System.IO.File]::ReadAllBytes($applicationHostPath)
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($applicationHostPath)

    $template = Get-SiteElement -Document $xml -SiteName $TemplateSite
    if (-not $template) { throw "Site IIS modèle introuvable : $TemplateSite" }
    if (Get-SiteElement -Document $xml -SiteName $TargetSite) { throw "Le site IIS '$TargetSite' existe déjà." }

    $sitesNode = $template.ParentNode
    $clone = $template.CloneNode($true)
    $clone.SetAttribute("name", $TargetSite)
    $maxId = 0
    foreach ($site in @($sitesNode.SelectNodes("site"))) {
        $id = 0
        if ([int]::TryParse($site.GetAttribute("id"), [ref]$id) -and $id -gt $maxId) { $maxId = $id }
    }
    $clone.SetAttribute("id", [string]($maxId + 1))

    foreach ($virtualDirectory in @($clone.SelectNodes(".//*[local-name()='virtualDirectory']"))) {
        if ($virtualDirectory.HasAttribute("physicalPath")) {
            $newPath = Get-SuffixedPath -Path $virtualDirectory.GetAttribute("physicalPath") -Suffix $Suffix
            $virtualDirectory.SetAttribute("physicalPath", $newPath)
            if (-not (Test-Path -LiteralPath $newPath)) { New-Item -ItemType Directory -Path $newPath -Force | Out-Null }
        }
    }
    foreach ($binding in @($clone.SelectNodes(".//*[local-name()='binding']"))) {
        $bindingInformation = $binding.GetAttribute("bindingInformation")
        $parts = $bindingInformation -split ':', 3
        if ($parts.Count -eq 3) {
            $parts[2] = Get-SuffixedHostName -HostName $parts[2] -Suffix $Suffix
            $binding.SetAttribute("bindingInformation", ($parts -join ':'))
        }
    }
    $null = $sitesNode.AppendChild($clone)

    # Les réglages site-level sont stockés sous des nœuds <location>. Les recopier
    # conserve notamment authentification, modules, rewrite et paramètres personnalisés.
    $locations = @($xml.SelectNodes("/configuration/location"))
    foreach ($location in $locations) {
        $locationPath = $location.GetAttribute("path")
        if ($locationPath -eq $TemplateSite -or $locationPath.StartsWith("$TemplateSite/")) {
            $locationClone = $location.CloneNode($true)
            $locationClone.SetAttribute("path", "$TargetSite$($locationPath.Substring($TemplateSite.Length))")
            $null = $xml.DocumentElement.AppendChild($locationClone)
        }
    }

    try {
        $xml.Save($applicationHostPath)
        if (-not (Get-Website -Name $TargetSite -ErrorAction SilentlyContinue)) { throw "IIS n'a pas chargé le site cloné '$TargetSite'." }
    }
    catch {
        [System.IO.File]::WriteAllBytes($applicationHostPath, $originalContent)
        throw
    }
}

function Remove-IisLocationConfiguration {
    param([string]$SiteName)
    $applicationHostPath = Join-Path $env:windir "System32\inetsrv\config\applicationHost.config"
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($applicationHostPath)
    $locations = @($xml.SelectNodes("/configuration/location"))
    $removed = $false
    foreach ($location in $locations) {
        $locationPath = $location.GetAttribute("path")
        if ($locationPath -eq $SiteName -or $locationPath.StartsWith("$SiteName/")) {
            $null = $xml.DocumentElement.RemoveChild($location)
            $removed = $true
        }
    }
    if ($removed) { $xml.Save($applicationHostPath) }
}

function Get-TemplateHostNames {
    param([string]$TemplateSite, [string]$Suffix)
    $website = Get-Website -Name $TemplateSite -ErrorAction Stop
    $hostNames = New-Object System.Collections.Generic.List[string]
    foreach ($binding in @($website.bindings.Collection)) {
        $parts = $binding.bindingInformation -split ':', 3
        if ($parts.Count -eq 3 -and -not [string]::IsNullOrWhiteSpace($parts[2])) {
            $hostNames.Add((Get-SuffixedHostName -HostName $parts[2] -Suffix $Suffix))
        }
    }
    return @($hostNames | Sort-Object -Unique)
}

function Update-WorkspaceHostsFile {
    param([string]$WorkspaceName, [string[]]$HostNames, [switch]$Remove)
    $hostsPath = Join-Path $env:windir "System32\drivers\etc\hosts"
    $marker = "# ws-tool:$WorkspaceName"
    $lines = if (Test-Path -LiteralPath $hostsPath) { @([System.IO.File]::ReadAllLines($hostsPath)) } else { @() }
    $keptLines = @($lines | Where-Object { $_ -notmatch [regex]::Escape($marker) })

    if (-not $Remove -and $HostNames.Count -gt 0) {
        $keptLines += ("127.0.0.1`t" + (($HostNames | Sort-Object -Unique) -join "`t") + "`t" + $marker)
    }

    [System.IO.File]::WriteAllLines($hostsPath, [string[]]$keptLines, (New-Object System.Text.UTF8Encoding($false)))
    if ($Remove) { Write-Host "Entrée hosts supprimée : $marker" -ForegroundColor Green }
    elseif ($HostNames.Count -gt 0) { Write-Host "Entrée hosts ajoutée : $($HostNames -join ', ')" -ForegroundColor Green }
}

function Add-PublishProfileCommitWarning {
    param([string]$RepositoryPath, [string]$RepositoryName)
    $workspacePath = Split-Path -Parent $RepositoryPath
    $agentsPath = Join-Path $workspacePath "AGENTS.md"
    if (-not (Test-Path -LiteralPath $agentsPath -PathType Leaf)) { return }

    $warning = "Ne jamais commit les modifications des profils de publication (.pubxml)."
    $lines = @([System.IO.File]::ReadAllLines($agentsPath))
    $repositoryPattern = "^\|\s*" + [regex]::Escape($RepositoryName) + "\s*\|"
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -notmatch $repositoryPattern -or $lines[$index].Contains($warning)) { continue }
        $columns = $lines[$index].Split('|')
        if ($columns.Count -lt 6) { continue }
        $role = $columns[3].Trim()
        $columns[3] = " $role - $warning "
        $lines[$index] = $columns -join '|'
        [System.IO.File]::WriteAllLines($agentsPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "AGENTS.md rule added for $RepositoryName." -ForegroundColor Green
        return
    }
}

if (-not (Test-Path -LiteralPath $WorkspaceConfig -PathType Leaf)) { throw "Configuration introuvable : $WorkspaceConfig" }
if (-not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) { throw "Repository introuvable : $RepositoryPath" }

$config = Get-Content -LiteralPath $WorkspaceConfig -Raw | ConvertFrom-Json
$repoProperty = $config.repos.PSObject.Properties[$RepositoryName]
if (-not $repoProperty -or -not (Test-Property -Object $repoProperty.Value -Name "iis") -or -not $repoProperty.Value.iis) { throw "La section 'repos.$RepositoryName.iis' est absente de $WorkspaceConfig." }

$repoIis = $repoProperty.Value.iis
if (-not (Test-Property -Object $repoIis -Name "sites") -or -not $repoIis.sites) { throw "La propriété 'repos.$RepositoryName.iis.sites' est obligatoire." }

Import-Module WebAdministration -ErrorAction Stop
$workspaceHostNames = New-Object System.Collections.Generic.List[string]
$publishDirectories = New-Object System.Collections.Generic.List[string]

foreach ($site in @($repoIis.sites)) {
    if (-not (Test-Property -Object $site -Name "name") -or -not $site.name) { throw "Chaque site IIS doit avoir une propriété 'name'." }
    $siteName = "$WorkspaceName-$($site.name)"
    if (-not (Test-Property -Object $site -Name "templateSite") -or -not $site.templateSite) { throw "Chaque site IIS doit définir un site modèle via 'templateSite'." }
    $templateSite = [string]$site.templateSite
    $templateWebsite = Get-Website -Name $templateSite -ErrorAction Stop
    foreach ($hostName in @(Get-TemplateHostNames -TemplateSite $templateSite -Suffix $WorkspaceName)) { $workspaceHostNames.Add($hostName) }

    if ($Remove) {
        $createdWebsite = Get-Website -Name $siteName -ErrorAction SilentlyContinue
        if ($createdWebsite) {
            $expectedPublishPath = Get-SuffixedPath -Path $templateWebsite.physicalPath -Suffix $WorkspaceName
            $actualPublishPath = [System.IO.Path]::GetFullPath($createdWebsite.physicalPath)
            if ($actualPublishPath -ieq [System.IO.Path]::GetFullPath($expectedPublishPath)) {
                $publishDirectories.Add($actualPublishPath)
            }
            else {
                Write-Warning "Le chemin du site '$siteName' diffère du chemin créé par ws ; il ne sera pas supprimé : $actualPublishPath"
            }
            Remove-Website -Name $siteName
            Remove-IisLocationConfiguration -SiteName $siteName
            Write-Host "Site IIS supprimé : $siteName" -ForegroundColor Green
        }
    }
    else {
        if (-not (Get-Website -Name $siteName -ErrorAction SilentlyContinue)) {
            Copy-TemplateIisSite -TemplateSite $templateSite -TargetSite $siteName -Suffix $WorkspaceName
            Write-Host "Site IIS cloné : $templateSite -> $siteName" -ForegroundColor Green
        }
    }

    if ((Test-Property -Object $site -Name "publishProfile") -and $site.publishProfile) {
        $profileRelativePath = [string]$site.publishProfile
        if ([System.IO.Path]::IsPathRooted($profileRelativePath)) { throw "publishProfile doit être relatif au repository : $profileRelativePath" }
        $profilePath = Join-Path $RepositoryPath $profileRelativePath
        if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
            if ($Remove) {
                Write-Host "Profil absent, restauration ignorée : $profileRelativePath" -ForegroundColor Yellow
                continue
            }
            throw "Profil de publication introuvable : $profilePath"
        }
        if ($Remove) {
            & git -C $RepositoryPath restore --worktree -- $profileRelativePath
            if ($LASTEXITCODE -ne 0) { throw "Impossible de restaurer le profil de publication : $profileRelativePath" }
            Write-Host "Profil restauré depuis Git : $profileRelativePath" -ForegroundColor Green
        }
        else {
            $createdSite = Get-Website -Name $siteName -ErrorAction Stop
            Set-PublishUrl -ProfilePath $profilePath -TargetPath $createdSite.physicalPath
            Write-Host "Profil mis à jour : $profileRelativePath -> $($createdSite.physicalPath)" -ForegroundColor Green
        }
    }
}

Update-WorkspaceHostsFile -WorkspaceName $WorkspaceName -HostNames @($workspaceHostNames | Sort-Object -Unique) -Remove:$Remove
if ($Remove) {
    foreach ($publishDirectory in @($publishDirectories | Sort-Object -Unique)) {
        if (Test-Path -LiteralPath $publishDirectory) {
            Remove-Item -LiteralPath $publishDirectory -Recurse -Force
            Write-Host "Dossier de publication supprimé : $publishDirectory" -ForegroundColor Green
        }
    }
    foreach ($workspacePublishDirectory in @($publishDirectories | ForEach-Object { Split-Path -Parent $_ } | Sort-Object -Unique)) {
        if ((Test-Path -LiteralPath $workspacePublishDirectory) -and -not (Get-ChildItem -LiteralPath $workspacePublishDirectory -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $workspacePublishDirectory -Force
            Write-Host "Dossier de publication du workspace supprimé : $workspacePublishDirectory" -ForegroundColor Green
        }
    }
}
if (-not $Remove) { Add-PublishProfileCommitWarning -RepositoryPath $RepositoryPath -RepositoryName $RepositoryName }
