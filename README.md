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
└── repos.json
```

Puis elle ajoute la fonction `ws` au profil PowerShell.

## Configuration

Modifier :

```text
%USERPROFILE%\.ws\repos.json
```

Exemple :

```json
{
  "workspacesRoot": "C:\\DEV\\agent-workspaces",
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
ws create feature-auth frontend backend
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
frontend : develop -> agent/feature-auth
backend  : develop -> agent/feature-auth
```

Si `agent/feature-auth` existe déjà dans un repo, la branche est réutilisée.

## Ouvrir

```powershell
ws open feature-auth
```

Ordre de préférence :

1. VS Code si `code` est disponible
2. Rider si `rider64.exe` est disponible
3. Explorateur Windows sinon

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

Les worktrees sont supprimés, mais les branches `agent/...` sont conservées.

Pour supprimer également les branches locales associées au workspace :

```powershell
ws remove feature-auth -DeleteBranches
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
