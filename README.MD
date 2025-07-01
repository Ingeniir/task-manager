# Gestionnaire de Tâches Powershell

Un module *Powershell* complet pour la gestion de tâches personelles, avec un support des priorités, échéances, tags, suivi du temps, archivage, et bien plus. Idéal pour les utilisateurs en lgine de commande souhaitant organiser efficacement leurs tâches.

## Fonctionnalités principales

- **Ajout, suppression, mise à jour et complétion de tâches**
- **Gestion des priorités** (`Low`, `Normal`, `High`, `Urgent`)
- **Échéances flexibles** (date précise, demain, semaine prochaine, etc.)
- **Tags et descriptions personnalisés**
- **Filtrage et tri avancés** (par priorité, date, tags, etc.)
- **Suivi du temps passé sur chaque tâches** (démarrage/arrêt du chrono)
- **Archivage et suppression des tâches complétées**
- **Rappels et affichage des tâches à venir ou en retard**
- **Statistiques globales et par priorité**

## Installation

1. Copiez le fichier `task-manager.psm1` dans un dossier de votre choix.
2. Importez le module dans votre session Powershell :

  ```ps1
  Import-Module "chemin\vers\task-manager.psm1"
  ```

## Commandes principales

| Commande             | Alias | Description                                 |
|----------------------|-------|---------------------------------------------|
| Add-Task             | at    | Ajouter une nouvelle tâche                  |
| Get-Tasks            | gt    | Lister les tâches (avec filtres)            |
| Complete-Task        | ct    | Marquer une tâche comme complétée           |
| Remove-Task          | rt    | Supprimer une tâche                         |
| Update-Task          | ut    | Modifier une tâche existante                |
| Get-TasksSummary     | gts   | Statistiques sur les tâches                 |
| Clear-CompletedTasks | cct   | Supprimer/archiver les tâches complétées    |
| Get-TaskDueSoon      | gtds  | Afficher les tâches à échéance prochaine    |
| Send-TaskReminder    |       | Rappel des tâches à venir                   |
| Start-TaskTimer      | lt    | Démarrer le chrono sur une tâche            |
| Stop-TaskTimer       | st    | Arrêter le chrono sur une tâche             |
| Get-TaskTime         | gtt   | Afficher le temps passé sur une tâche       |

Utilisez `Get-Help <commande>` pour plus de détails sur chaque commande.

## Exemples d'utilisation

Ajouter une tâche

```ps1
Add-Task -Description "Rédiger le rapport" -DueDate "2025-07-05" -Priority High -Tags "travail","urgent" -Notes "Rapport mensuel à remettre"
```

ou

```ps1
at "Rédiger le rapport" -DueDate "2025-07-05" -Priority High -Tags "travail","urgent" -Description "Rapport mensuel à remettre"
```

Lister les tâches en attente, triées par priorité :

```ps1
Get-Tasks -Pending -SortBy Priority
```

Marquer une tâche comme complétée :

```ps1
Complete-Task -IdOrDescription "Rédiger le rapport"
```

Démarrer et arrêter le chrono sur une tâche :

```ps1
Start-TaskTimer -Description "Rédiger le rapport"
# ... travail sur la tâche ...
Stop-TaskTimer -Description "Rédiger le rapport"
```

Afficher les statistiques

```ps1
Get-TasksSummary -Detailed
```

### Stockage des données

- Les tâches sont sauvegardées dans un fichier JSON dans votre dossier utilisateur (`task-manager.json`).
- Les tâches archivées sont stockées dans un fichier séparé (`task-manager-archive.json`).

### Personnalisation

- **Priorité** : `Low`, `Normal`, `High`, `Urgent`
- **Tags** : Ajoutez des tags pour filtrer et organiser vos tâches.
- **Échéances** : Précisez une date, ou utiliser les options `-DueTomorrow`, `-DueNextWeek`.

### Astuces

- Utilisez les alias pour aller plus vite (`at`, `gt`, `ct`, etc.).
- Combinez les filtres pour des recherches précises (par exemple, tâches urgentes en retard).
- Le suivi du temps vous permet de mesurer précisément l'effort consacré à chaque tâche.

### Export des fonctions et alias

Toutes les fonctions principales et leurs alias sont exportés automatiquement à l'import du module.
