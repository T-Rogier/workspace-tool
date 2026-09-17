# ws — Git workspaces multi-repositories

Petit outil PowerShell pour créer des workspaces destinés à des agents ou IDE travaillant en parallèle sur plusieurs repositories Git.

## Installation

```powershell
.\install.ps1
. $PROFILE
```

L'installation copie l'outil dans :

```text
%USERPROFILE%\.ws\
├── ws.ps1
└── config.json
```

Puis elle ajoute la fonction `ws` au profil PowerShell.

## Configuration

Modifier :

```text
%USERPROFILE%\.ws\config.json
```

Lors d'une mise à jour via `install.ps1`, une ancienne configuration `repos.json` est automatiquement renommée en `config.json`.

Exemple :

```json
{
  "workspacesRoot": "C:\\DEV\\agent-workspaces",
  "editorOrder": ["cursor", "code", "rider", "explorer"],
  "repos": {
    "frontend": {
      "path": "C:\\DEV\\Rustkins.Frontend",
      "description": "Frontend web de Rustkins",
      "defaultBranch": "develop",
      "dependsOn": ["backend"]
    },
    "backend": {
      "path": "C:\\DEV\\Rustkins.Backend",
      "description": "API et logique métier de Rustkins",
      "defaultBranch": "develop"
    }
  }
}
```

## Créer un workspace

```powershell
ws create feature-auth frontend backend -BranchType feature
```

Ajoute `-o` pour ouvrir automatiquement le workspace après sa création :

```powershell
ws create feature-auth frontend backend -o
```

Les alias courts sont : `-t` pour `-BranchType`, `-o` pour `-OpenAfterCreate` et `-d` pour `-DeleteBranches`.

```powershell
ws create correction-login frontend -t fix
ws remove correction-login -d
```

Crée :

```text
C:\DEV\agent-workspaces\
└── feature-auth\
    ├── .workspace.json
    ├── AGENTS.md
    ├── frontend\
    └── backend\
```

Branches :

```text
frontend : develop -> feature/feature-auth
backend  : develop -> feature/feature-auth
```

Le type est libre, tant qu'il est compatible avec un préfixe Git :

```powershell
ws create correction-login frontend backend -BranchType fix
ws create guide-installation frontend -BranchType docs
```

Cela crée respectivement les branches `fix/correction-login` et `docs/guide-installation`.
Sans `-BranchType`, le type par défaut est `feature` : `feature/<workspace>`.

Un paramètre inconnu commençant par `-` produit une erreur explicite.

Si la branche existe déjà dans un repo, elle est réutilisée.

## Scripts post-création

`ws` reste neutre : il crée les worktrees puis exécute uniquement les scripts déclarés dans `postCreate` et `postDelete`. Les variables disponibles sont `{workspaceName}`, `{branchName}`, `{repoName}`, `{worktreePath}`, `{workspacePath}`, `{configPath}` et `{toolPath}`.

Le script fourni `scripts\\New-FeatureIis.ps1` est un exemple de script post-création : il crée les sites IIS et réécrit les `PublishUrl` des profils de publication du worktree. Il est spécifique à cette organisation IIS, pas au fonctionnement de `ws`.

```json
{
  "workspacesRoot": "C:\\DEV\\agent-workspaces",
  "repos": {
    "web": {
      "path": "C:\\DEV\\My.Web",
      "defaultBranch": "develop",
      "iis": {
        "sites": [
          {
            "name": "web",
            "templateSite": "web",
            "publishProfile": "My.Web\\Properties\\PublishProfiles\\FolderProfile.pubxml"
          }
        ]
      },
      "postCreate": {
        "script": "{toolPath}\\scripts\\New-FeatureIis.ps1",
        "arguments": [
          "-WorkspaceConfig", "{configPath}",
          "-WorkspaceName", "{workspaceName}",
          "-RepositoryName", "{repoName}",
          "-RepositoryPath", "{worktreePath}"
        ]
      },
      "postDelete": {
        "script": "{toolPath}\\scripts\\New-FeatureIis.ps1",
        "arguments": [
          "-WorkspaceConfig", "{configPath}",
          "-WorkspaceName", "{workspaceName}",
          "-RepositoryName", "{repoName}",
          "-RepositoryPath", "{worktreePath}",
          "-Remove"
        ]
      }
    },
    "api": {
      "path": "C:\\DEV\\My.Api",
      "defaultBranch": "develop",
      "postCreate": {
        "script": "scripts\\prepare-local.ps1",
        "arguments": ["-Workspace", "{workspaceName}"]
      }
    }
  }
}
```

Chaque entrée de `iis.sites` doit définir `templateSite`, le nom du site IIS local servant de modèle. Le script clone entièrement ce site : pool applicatif, bindings HTTP/HTTPS, certificat et réglages spécifiques. Il applique le suffixe du workspace au dernier dossier de chaque chemin physique et au premier libellé de chaque nom d'hôte. Ainsi `C:\\inetpub\\wwwroot\\web` devient `C:\\inetpub\\wwwroot\\web-feature-auth`, et `web.dijon.fr` devient `web-feature-auth.dijon.fr`. Le profil indiqué par `publishProfile` est ensuite mis à jour dans le worktree afin que son élément `PublishUrl` cible le chemin cloné.

Les noms d'hôte clonés sont ajoutés au fichier Windows `hosts` sous une entrée marquée `# ws-tool:<workspace>` et pointent vers `127.0.0.1`. Le hook `postDelete` retire uniquement cette entrée, sans modifier les autres lignes du fichier.

Après la création, le script IIS ajoute également au `AGENTS.md` du workspace une règle dans la description du repository concerné : ne jamais commiter les modifications des profils de publication (`.pubxml`).

La création et la suppression de sites IIS requièrent une console PowerShell lancée en administrateur. Au retrait du workspace, le script IIS supprime les sites et restaure les `publishProfile` avec `git restore` avant que `ws` ne supprime le worktree.

## Ouvrir

```powershell
ws open feature-auth
```

L'ordre d'ouverture se règle avec `editorOrder` dans `config.json`. Les valeurs disponibles sont `code`, `cursor`, `rider` et `explorer` ; le premier éditeur disponible est utilisé. Par exemple, pour préférer Cursor :

```json
"editorOrder": ["cursor", "code", "rider", "explorer"]
```

Sans cette propriété, l'ordre par défaut est :

1. VS Code si `code` est disponible
2. Cursor si `cursor` est disponible
3. Rider si `rider64.exe` est disponible
4. Explorateur Windows sinon

## Lister

```powershell
ws list
```

## Statut

```powershell
ws status feature-auth
```

Affiche par repository :

- branche courante
- branche de base
- fichiers modifiés
- commits ahead
- commits behind

## Supprimer

```powershell
ws remove feature-auth
```

Les worktrees sont supprimés, mais les branches (`feature/...`, `fix/...`, etc.) sont conservées.

Pour supprimer également les branches locales associées au workspace :

```powershell
ws remove feature-auth -DeleteBranches
```

Ou avec son alias :

```powershell
ws remove feature-auth -d
```

Git refuse cette suppression si une branche contient des commits non fusionnés. Les branches distantes ne sont jamais supprimées.

Si un worktree contient des modifications non commitées, la suppression s'arrête afin d'éviter une perte de données.

## AGENTS.md

Le fichier `AGENTS.md` généré à la racine décrit automatiquement :

- les repositories présents
- leur rôle
- leurs branches
- leurs branches de base
- les relations `dependsOn`
- les règles pour travailler dans un workspace multi-repositories

Les `AGENTS.md` propres à chaque repository restent indépendants et peuvent contenir les conventions spécifiques au projet.
