param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("create", "open", "list", "status", "remove")]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$WorkspaceName,

    [Parameter(Position = 2, ValueFromRemainingArguments = $true)]
    [string[]]$Repositories,

    [switch]$DeleteBranches
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptRoot "repos.json"

function Get-Config {
    if (-not (Test-Path $ConfigPath)) { throw "Configuration introuvable : $ConfigPath" }
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if (-not $config.workspacesRoot) { throw "La propriété 'workspacesRoot' est obligatoire dans repos.json." }
    if (-not $config.repos) { throw "La propriété 'repos' est obligatoire dans repos.json." }
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

function Assert-GitRepo {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Le chemin du repository n'existe pas : $Path" }
    $result = & git -C $Path rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or $result -ne "true") { throw "Le chemin n'est pas un repository Git valide : $Path" }
}

function Get-WorkspacePath { param($Config, [string]$Name) return (Join-Path $Config.workspacesRoot $Name) }
function Get-AgentBranch { param([string]$WorkspaceName) return "agent/$WorkspaceName" }

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

function Write-WorkspaceManifest {
    param([string]$WorkspacePath, [string]$WorkspaceName, [string]$BranchName, [array]$RepoEntries)
    $manifest = [PSCustomObject]@{
        name = $WorkspaceName
        branch = $BranchName
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
    param($Config, [string]$Name, [string[]]$RepoNames)
    if (-not $RepoNames -or $RepoNames.Count -eq 0) { throw "Usage : ws create <workspace> <repo1> [repo2] [...]" }
    $workspacePath = Get-WorkspacePath -Config $Config -Name $Name
    if (Test-Path $workspacePath) { throw "Le workspace existe déjà : $workspacePath" }
    $branchName = Get-AgentBranch -WorkspaceName $Name
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

        Write-WorkspaceManifest -WorkspacePath $workspacePath -WorkspaceName $Name -BranchName $branchName -RepoEntries $repoEntries
        Write-AgentsFile -WorkspacePath $workspacePath -WorkspaceName $Name -RepoEntries $repoEntries

        Write-Host ""
        Write-Host "Workspace créé :" -ForegroundColor Green
        Write-Host "  $workspacePath"
        Write-Host ""
        foreach ($repo in $repoEntries) { Write-Host "  $($repo.name) : $($repo.defaultBranch) -> $($repo.branch)" }
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
    if (Get-Command code -ErrorAction SilentlyContinue) { & code $workspacePath }
    elseif (Get-Command rider64.exe -ErrorAction SilentlyContinue) { & rider64.exe $workspacePath }
    else { Invoke-Item $workspacePath }
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
    if ($repos.Count -eq 0) { throw "Impossible de supprimer proprement le workspace : manifest .workspace.json introuvable." }

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

    if (Test-Path $workspacePath) { Remove-Item $workspacePath -Recurse -Force }
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
        if (-not $WorkspaceName) { throw "Usage : ws create <workspace> <repo1> [repo2] [...]" }
        New-Workspace -Config $config -Name $WorkspaceName -RepoNames $Repositories
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
