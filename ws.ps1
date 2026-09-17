param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("create", "open", "list", "status", "remove")]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$WorkspaceName,

    [Parameter(Position = 2, ValueFromRemainingArguments = $true)]
    [string[]]$Repositories,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$BranchType = "feature",

    [Alias("o")]
    [switch]$OpenAfterCreate,

    [switch]$DeleteBranches
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptRoot "config.json"

function Get-Config {
    if (-not (Test-Path $ConfigPath)) { throw "Configuration introuvable : $ConfigPath" }
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if (-not $config.workspacesRoot) { throw "La propriété 'workspacesRoot' est obligatoire dans config.json." }
    if (-not $config.repos) { throw "La propriété 'repos' est obligatoire dans config.json." }
    return $config
}

function Get-RepoConfig {
    param($Config, [string]$RepoName)
    $repo = $Config.repos.PSObject.Properties[$RepoName]
    if (-not $repo) {
        $available = ($Config.repos.PSObject.Properties.Name | Sort-Object) -join ", "
        throw "Repository inconnu '$RepoName'. Repositories disponibles : $available"
    }
    $repoConfig = $repo.Value
    if (-not $repoConfig.path) { throw "Le repository '$RepoName' n'a pas de propriété 'path'." }
    if (-not $repoConfig.defaultBranch) { throw "Le repository '$RepoName' n'a pas de propriété 'defaultBranch'." }
    return $repoConfig
}

function Expand-WorkspaceTemplate {
    param([string]$Value, $Variables)
    if ($null -eq $Value) { return $null }
    foreach ($property in $Variables.PSObject.Properties) {
        $Value = $Value.Replace("{$($property.Name)}", [string]$property.Value)
    }
    return $Value
}

function Invoke-RepositoryHook {
    param($RepoConfig, [string]$HookName, $Variables, [string]$WorktreePath, [string]$RepoName)
    if (-not ($RepoConfig.PSObject.Properties.Name -contains $HookName) -or -not $RepoConfig.$HookName) { return }
    $hook = $RepoConfig.$HookName
    if (-not ($hook.PSObject.Properties.Name -contains "script") -or -not $hook.script) { throw "Le repository '$RepoName' a un $HookName sans propriété 'script'." }
    $scriptPath = Expand-WorkspaceTemplate -Value ([string]$hook.script) -Variables $Variables
    if (-not [System.IO.Path]::IsPathRooted($scriptPath)) { $scriptPath = Join-Path $WorktreePath $scriptPath }
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Script postCreate introuvable pour '$RepoName' : $scriptPath" }
    $arguments = @()
    if (($hook.PSObject.Properties.Name -contains "arguments") -and $hook.arguments) {
        $arguments = @($hook.arguments | ForEach-Object { Expand-WorkspaceTemplate -Value ([string]$_) -Variables $Variables })
    }
    Write-Host "Exécution $HookName : $scriptPath $($arguments -join ' ')" -ForegroundColor Cyan

    # PowerShell does not reinterpret strings from an array as named parameters
    # when calling a script. Convert the JSON argument convention (-Name value)
    # into a proper splatted hashtable so hook scripts receive their parameters.
    $namedArguments = @{}
    $positionalArguments = @()
    for ($index = 0; $index -lt $arguments.Count; $index++) {
        $argument = [string]$arguments[$index]
        if ($argument.StartsWith("-") -and $argument.Length -gt 1) {
            $parameterName = $argument.TrimStart("-")
            if ($index + 1 -lt $arguments.Count -and -not ([string]$arguments[$index + 1]).StartsWith("-")) {
                $namedArguments[$parameterName] = $arguments[$index + 1]
                $index++
            }
            else {
                $namedArguments[$parameterName] = $true
            }
        }
        else {
            $positionalArguments += $argument
        }
    }
    $global:LASTEXITCODE = 0
    & $scriptPath @namedArguments @positionalArguments
    if ($LASTEXITCODE -ne 0) { throw "Le script $HookName du repository '$RepoName' a échoué (code $LASTEXITCODE)." }
}

function Assert-GitRepo {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Le chemin du repository n'existe pas : $Path" }
    $result = & git -C $Path rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or $result -ne "true") { throw "Le chemin n'est pas un repository Git valide : $Path" }
}

function Get-WorkspacePath { param($Config, [string]$Name) return (Join-Path $Config.workspacesRoot $Name) }
function Get-WorkspaceBranch {
    param([string]$WorkspaceName, [string]$BranchType)

    if ([string]::IsNullOrWhiteSpace($WorkspaceName)) { throw "Le nom du workspace ne peut pas etre vide." }
    if ($WorkspaceName -match '[~^:?*\[\\ ]' -or $WorkspaceName.EndsWith('.') -or $WorkspaceName.EndsWith('/') -or $WorkspaceName.Contains('..')) {
        throw "Nom de workspace invalide pour une branche Git : '$WorkspaceName'"
    }

    return "$BranchType/$WorkspaceName"
}

function Invoke-Git {
    param([string]$RepoPath, [string[]]$Arguments)
    & git -C $RepoPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Commande Git échouée dans '$RepoPath' : git $($Arguments -join ' ')" }
}

function Test-BranchExists {
    param([string]$RepoPath, [string]$BranchName)
    & git -C $RepoPath show-ref --verify --quiet "refs/heads/$BranchName"
    return ($LASTEXITCODE -eq 0)
}

function Get-CurrentBranch {
    param([string]$Path)
    $branch = & git -C $Path branch --show-current
    if ($LASTEXITCODE -ne 0) { return "?" }
    return $branch.Trim()
}

function Get-GitStatusSummary {
    param([string]$Path, [string]$DefaultBranch)
    $modified = (& git -C $Path status --porcelain | Measure-Object).Count
    $ahead = "?"; $behind = "?"
    $null = & git -C $Path rev-parse --verify --quiet $DefaultBranch 2>$null
    if ($LASTEXITCODE -eq 0) {
        $counts = & git -C $Path rev-list --left-right --count "$DefaultBranch...HEAD" 2>$null
        if ($LASTEXITCODE -eq 0 -and $counts) {
            $parts = $counts -split "\s+"
            if ($parts.Count -ge 2) { $behind = $parts[0]; $ahead = $parts[1] }
        }
    }
    return [PSCustomObject]@{ Modified = $modified; Ahead = $ahead; Behind = $behind }
}

function Get-WorkspaceRepos {
    param([string]$WorkspacePath)
    $manifestPath = Join-Path $WorkspacePath ".workspace.json"
    if (-not (Test-Path $manifestPath)) { return @() }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    return @($manifest.repositories)
}

function Remove-WorkspaceDirectory {
    param([string]$WorkspacePath)
    $lastError = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            if (Test-Path $WorkspacePath) { Remove-Item $WorkspacePath -Recurse -Force }
            return
        }
        catch {
            $lastError = $_
            if ($attempt -lt 10) { Start-Sleep -Milliseconds 500 }
        }
    }
    throw $lastError
}

function Write-WorkspaceManifest {
    param([string]$WorkspacePath, [string]$WorkspaceName, [string]$BranchName, [string]$BranchType, [array]$RepoEntries)
    $manifest = [PSCustomObject]@{
        name = $WorkspaceName
        branch = $BranchName
        branchType = $BranchType
        createdAt = (Get-Date).ToString("o")
        repositories = $RepoEntries
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $WorkspacePath ".workspace.json") -Encoding UTF8
}

function Write-AgentsFile {
    param([string]$WorkspacePath, [string]$WorkspaceName, [array]$RepoEntries)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Workspace — $WorkspaceName")
    $lines.Add("")
    $lines.Add('Ce workspace est dédié à la tâche `' + $WorkspaceName + '`.')
    $lines.Add("")
    $lines.Add("## Repositories")
    $lines.Add("")
    $lines.Add("| Repository | Dossier | Rôle | Branche | Branche de base |")
    $lines.Add("|---|---|---|---|---|")

    foreach ($repo in $RepoEntries) {
        $description = if ($repo.description) { $repo.description } else { "" }
        $lines.Add("| $($repo.name) | " + '`./' + $repo.name + '`' + " | $description | " + '`' + $repo.branch + '`' + " | " + '`' + $repo.defaultBranch + '`' + " |")
    }

    $lines.Add("")
    $lines.Add("## Règles de travail")
    $lines.Add("")
    $lines.Add("- Chaque dossier est un repository Git indépendant.")
    $lines.Add("- Ne jamais considérer la racine de ce workspace comme un repository Git.")
    $lines.Add('- Consulter le fichier `AGENTS.md` propre à chaque repository s''il existe.')
    $lines.Add("- Toujours exécuter les commandes Git depuis le repository concerné.")
    $lines.Add("- Les commits doivent être réalisés séparément dans chaque repository.")
    $lines.Add("- Vérifier les impacts inter-repositories avant de modifier une API, un contrat, un modèle ou une interface partagée.")
    $lines.Add("- Ne pas modifier un autre repository sans nécessité liée à la tâche courante.")

    $relations = New-Object System.Collections.Generic.List[string]
    foreach ($repo in $RepoEntries) {
        if ($repo.dependsOn) {
            foreach ($dependency in @($repo.dependsOn)) {
                if ($RepoEntries.name -contains $dependency) {
                    $relations.Add('- `' + $repo.name + '` dépend de `' + $dependency + '`.')
                }
            }
        }
    }

    if ($relations.Count -gt 0) {
        $lines.Add("")
        $lines.Add("## Relations")
        $lines.Add("")
        foreach ($relation in $relations) { $lines.Add($relation) }
        $lines.Add("")
        $lines.Add("Toute modification d'un contrat partagé doit être vérifiée dans les repositories consommateurs.")
    }

    $lines.Add("")
    $lines.Add("## Structure")
    $lines.Add("")
    $lines.Add('```text')
    $lines.Add(".")
    $lines.Add("├── AGENTS.md")
    for ($i = 0; $i -lt $RepoEntries.Count; $i++) {
        $prefix = if ($i -eq $RepoEntries.Count - 1) { "└──" } else { "├──" }
        $lines.Add("$prefix $($RepoEntries[$i].name)/")
    }
    $lines.Add('```')

    $lines | Set-Content (Join-Path $WorkspacePath "AGENTS.md") -Encoding UTF8
}

function New-Workspace {
    param($Config, [string]$Name, [string[]]$RepoNames, [string]$BranchType, [switch]$OpenAfterCreate)
    if (-not $RepoNames -or $RepoNames.Count -eq 0) { throw "Usage : ws create <workspace> <repo1> [repo2] [...] [-BranchType <type>]" }
    $workspacePath = Get-WorkspacePath -Config $Config -Name $Name
    if (Test-Path $workspacePath) { throw "Le workspace existe déjà : $workspacePath" }
    $branchName = Get-WorkspaceBranch -WorkspaceName $Name -BranchType $BranchType
    New-Item -ItemType Directory -Path $workspacePath -Force | Out-Null
    $createdWorktrees = New-Object System.Collections.Generic.List[object]

    try {
        $repoEntries = @()
        foreach ($repoName in $RepoNames) {
            $repoConfig = Get-RepoConfig -Config $Config -RepoName $repoName
            $repoPath = [System.IO.Path]::GetFullPath($repoConfig.path)
            $worktreePath = Join-Path $workspacePath $repoName
            Assert-GitRepo -Path $repoPath

            Write-Host ""
            Write-Host "[$repoName]" -ForegroundColor Cyan
            Write-Host "Source : $repoPath"
            Write-Host "Base   : $($repoConfig.defaultBranch)"
            Write-Host "Branch : $branchName"
            Write-Host "Target : $worktreePath"

            # Updating refs is required before creating the worktree, but pruning
            # unrelated deleted branches must not prevent workspace creation.
            Invoke-Git -RepoPath $repoPath -Arguments @("fetch", "--all")

            if (Test-BranchExists -RepoPath $repoPath -BranchName $branchName) {
                Write-Host "La branche existe déjà, réutilisation." -ForegroundColor Yellow
                Invoke-Git -RepoPath $repoPath -Arguments @("worktree", "add", $worktreePath, $branchName)
            }
            else {
                Invoke-Git -RepoPath $repoPath -Arguments @("worktree", "add", "-b", $branchName, $worktreePath, $repoConfig.defaultBranch)
            }

            $createdWorktrees.Add([PSCustomObject]@{ RepoPath = $repoPath; WorktreePath = $worktreePath })
            $dependsOn = @()
            if ($repoConfig.PSObject.Properties.Name -contains "dependsOn" -and $repoConfig.dependsOn) { $dependsOn = @($repoConfig.dependsOn) }

            $repoEntries += [PSCustomObject]@{
                name = $repoName
                path = $repoPath
                worktreePath = $worktreePath
                description = $repoConfig.description
                defaultBranch = $repoConfig.defaultBranch
                branch = $branchName
                dependsOn = $dependsOn
            }
        }

        Write-WorkspaceManifest -WorkspacePath $workspacePath -WorkspaceName $Name -BranchName $branchName -BranchType $BranchType -RepoEntries $repoEntries
        Write-AgentsFile -WorkspacePath $workspacePath -WorkspaceName $Name -RepoEntries $repoEntries

        # Hooks run after the workspace metadata is generated, so a repository
        # script can enrich AGENTS.md without its changes being overwritten.
        foreach ($repo in $repoEntries) {
            $repoConfig = Get-RepoConfig -Config $Config -RepoName $repo.name
            $templateVariables = [PSCustomObject]@{
                workspaceName = $Name
                branchName = $branchName
                repoName = $repo.name
                worktreePath = $repo.worktreePath
                workspacePath = $workspacePath
                configPath = $ConfigPath
                toolPath = $ScriptRoot
            }
            Invoke-RepositoryHook -RepoConfig $repoConfig -HookName "postCreate" -Variables $templateVariables -WorktreePath $repo.worktreePath -RepoName $repo.name
        }

        Write-Host ""
        Write-Host "Workspace créé :" -ForegroundColor Green
        Write-Host "  $workspacePath"
        Write-Host ""
        foreach ($repo in $repoEntries) { Write-Host "  $($repo.name) : $($repo.defaultBranch) -> $($repo.branch)" }

        if ($OpenAfterCreate) {
            Open-Workspace -Config $Config -Name $Name
        }
    }
    catch {
        Write-Warning "Erreur pendant la création. Nettoyage des worktrees déjà créés..."
        foreach ($item in $createdWorktrees) {
            try { & git -C $item.RepoPath worktree remove --force $item.WorktreePath 2>$null } catch {}
        }
        if (Test-Path $workspacePath) { Remove-Item $workspacePath -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Open-Workspace {
    param($Config, [string]$Name)
    $workspacePath = Get-WorkspacePath -Config $Config -Name $Name
    if (-not (Test-Path $workspacePath)) { throw "Workspace introuvable : $Name" }

    $editorOrder = @("code", "cursor", "rider", "explorer")
    if ($Config.PSObject.Properties.Name -contains "editorOrder" -and $Config.editorOrder) {
        $editorOrder = @($Config.editorOrder)
    }

    foreach ($editor in $editorOrder) {
        switch ([string]$editor) {
            "code" {
                if (Get-Command code -ErrorAction SilentlyContinue) { & code $workspacePath; return }
            }
            "cursor" {
                if (Get-Command cursor -ErrorAction SilentlyContinue) { & cursor $workspacePath; return }
            }
            "rider" {
                if (Get-Command rider64.exe -ErrorAction SilentlyContinue) { & rider64.exe $workspacePath; return }
            }
            "explorer" { Invoke-Item $workspacePath; return }
            default { throw "Editeur inconnu dans editorOrder : '$editor'. Valeurs acceptees : code, cursor, rider, explorer." }
        }
    }

    throw "Aucun editeur configure n'est disponible pour ouvrir '$workspacePath'."
}

function Show-Workspaces {
    param($Config)
    $root = $Config.workspacesRoot
    if (-not (Test-Path $root)) { Write-Host "Aucun workspace."; return }
    $items = @(Get-ChildItem $root -Directory | Sort-Object Name)
    if ($items.Count -eq 0) { Write-Host "Aucun workspace."; return }
    $rows = foreach ($item in $items) {
        $manifestPath = Join-Path $item.FullName ".workspace.json"
        if (Test-Path $manifestPath) {
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
            [PSCustomObject]@{ Workspace = $item.Name; Repositories = (@($manifest.repositories).name -join ", "); Branch = $manifest.branch; Path = $item.FullName }
        }
        else {
            [PSCustomObject]@{ Workspace = $item.Name; Repositories = "?"; Branch = "?"; Path = $item.FullName }
        }
    }
    $rows | Format-Table -AutoSize
}

function Show-WorkspaceStatus {
    param($Config, [string]$Name)
    $workspacePath = Get-WorkspacePath -Config $Config -Name $Name
    if (-not (Test-Path $workspacePath)) { throw "Workspace introuvable : $Name" }
    $repos = @(Get-WorkspaceRepos -WorkspacePath $workspacePath)
    if ($repos.Count -eq 0) { throw "Manifest .workspace.json introuvable ou vide dans '$workspacePath'." }

    Write-Host "Workspace: $Name" -ForegroundColor Cyan
    Write-Host ""
    foreach ($repo in $repos) {
        $path = Join-Path $workspacePath $repo.name
        if (-not (Test-Path $path)) {
            Write-Host "$($repo.name)" -ForegroundColor Red
            Write-Host "  worktree manquant: $path"
            Write-Host ""
            continue
        }
        $branch = Get-CurrentBranch -Path $path
        $summary = Get-GitStatusSummary -Path $path -DefaultBranch $repo.defaultBranch
        Write-Host "$($repo.name)" -ForegroundColor Yellow
        Write-Host "  branch   : $branch"
        Write-Host "  base     : $($repo.defaultBranch)"
        Write-Host "  modified : $($summary.Modified) fichier(s)"
        Write-Host "  ahead    : $($summary.Ahead) commit(s)"
        Write-Host "  behind   : $($summary.Behind) commit(s)"
        Write-Host ""
    }
}

function Remove-Workspace {
    param($Config, [string]$Name, [switch]$DeleteBranches)
    $workspacePath = Get-WorkspacePath -Config $Config -Name $Name
    if (-not (Test-Path $workspacePath)) { throw "Workspace introuvable : $Name" }
    $repos = @(Get-WorkspaceRepos -WorkspacePath $workspacePath)
    if ($repos.Count -eq 0) {
        # A previous removal can finish all Git operations yet fail only while
        # deleting the root directory because Windows still has it locked.
        # Permit a later retry when no worktree marker remains, without rerunning
        # lifecycle hooks or attempting to delete branches a second time.
        $gitMarkers = @(Get-ChildItem -Path $workspacePath -Force -Recurse -Filter ".git" -ErrorAction SilentlyContinue)
        if ($gitMarkers.Count -gt 0) { throw "Impossible de supprimer proprement le workspace : manifest .workspace.json introuvable et worktree(s) encore présent(s)." }
        try {
            Remove-WorkspaceDirectory -WorkspacePath $workspacePath
            Write-Host "Résidu du workspace '$Name' supprimé." -ForegroundColor Green
            return
        }
        catch {
            throw "Les worktrees et branches ont déjà été traités, mais le dossier '$workspacePath' est encore utilisé par un processus. Ferme l'Explorateur, un terminal ou un IDE ouvert sur ce dossier puis relance : ws remove $Name"
        }
    }

    foreach ($repo in $repos) {
        $worktreePath = Join-Path $workspacePath $repo.name
        if (-not (Test-Path $worktreePath)) { continue }
        $repoConfig = Get-RepoConfig -Config $Config -RepoName $repo.name
        $templateVariables = [PSCustomObject]@{
            workspaceName = $Name
            branchName = $repo.branch
            repoName = $repo.name
            worktreePath = $worktreePath
            workspacePath = $workspacePath
            configPath = $ConfigPath
            toolPath = $ScriptRoot
        }
        Invoke-RepositoryHook -RepoConfig $repoConfig -HookName "postDelete" -Variables $templateVariables -WorktreePath $worktreePath -RepoName $repo.name
    }

    foreach ($repo in $repos) {
        $worktreePath = Join-Path $workspacePath $repo.name
        if (Test-Path $worktreePath) {
            Write-Host "Suppression du worktree '$($repo.name)'..."
            & git -C $repo.path worktree remove $worktreePath
            if ($LASTEXITCODE -ne 0) {
                Write-Host ""
                Write-Host "Le worktree '$($repo.name)' contient probablement des modifications non commitées." -ForegroundColor Yellow
                Write-Host "Utilise 'git status' dans : $worktreePath"
                throw "Suppression annulée."
            }
        }
        & git -C $repo.path worktree prune 2>$null
    }

    if ($DeleteBranches) {
        foreach ($repo in $repos) {
            $branchName = $repo.branch
            if (Test-BranchExists -RepoPath $repo.path -BranchName $branchName) {
                Write-Host "Suppression de la branche locale '$branchName' dans '$($repo.name)'..."
                Invoke-Git -RepoPath $repo.path -Arguments @("branch", "--delete", $branchName)
            }
        }
    }

    if (Test-Path $workspacePath) {
        try { Remove-WorkspaceDirectory -WorkspacePath $workspacePath }
        catch {
            throw "Les worktrees et branches ont été supprimés, mais le dossier '$workspacePath' est encore utilisé par un processus. Ferme l'Explorateur, un terminal ou un IDE ouvert sur ce dossier puis relance : ws remove $Name"
        }
    }
    Write-Host "Workspace '$Name' supprimé." -ForegroundColor Green
    if ($DeleteBranches) {
        Write-Host "Les branches Git locales associées ont été supprimées."
    }
    else {
        Write-Host "Les branches Git ont été conservées."
    }
}

$config = Get-Config

switch ($Command) {
    "create" {
        if (-not $WorkspaceName) { throw "Usage : ws create <workspace> <repo1> [repo2] [...] [-BranchType <type>]" }
        New-Workspace -Config $config -Name $WorkspaceName -RepoNames $Repositories -BranchType $BranchType -OpenAfterCreate:$OpenAfterCreate
    }
    "open" {
        if (-not $WorkspaceName) { throw "Usage : ws open <workspace>" }
        Open-Workspace -Config $config -Name $WorkspaceName
    }
    "list" { Show-Workspaces -Config $config }
    "status" {
        if (-not $WorkspaceName) { throw "Usage : ws status <workspace>" }
        Show-WorkspaceStatus -Config $config -Name $WorkspaceName
    }
    "remove" {
        if (-not $WorkspaceName) { throw "Usage : ws remove <workspace> [-DeleteBranches]" }
        Remove-Workspace -Config $config -Name $WorkspaceName -DeleteBranches:$DeleteBranches
    }
}
