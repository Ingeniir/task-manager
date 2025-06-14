# Configuration
$script:TaskFilePath = Join-Path -Path $env:USERPROFILE -ChildPath "task-manager.json"
$script:ArchiveFilePath = Join-Path -Path $env:USERPROFILE -ChildPath "task-manager-archive.json"
$script:TaskList = @()
$script:NextTaskId = 1

enum TaskPriority {
  Low
  Normal
  High
  Urgent
}

class PSTask {
  [int]$Id # Identifiant unique de la tâche
  [ValidateNotNullOrEmpty()]
  [string]$Title # Titre de la tâche (obligatoire & unique)
  [datetime]$CreatedAt # Date de création de la tâche
  [datetime]$DueDate # Date d'échéance de la tâche
  [bool]$Completed # Indique si la tâche est terminée
  [TaskPriority]$Priority # Priorité de la tâche
  [string[]]$Tags # Liste de tags associés à la tâche
  [string]$Description # Description de la tâche
  [timespan]$TimeSpent # Temps passé sur la tâche
  [datetime]$CurrentStartTime # Heure de début actuelle de la tâche

  # Constructeur de la classe PSTask
  PSTask() {
    $this.CreatedAt = Get-Date # Date de création par défaut
    $this.Completed = $false # Tâche non complétée par défaut
    $this.Priority = [TaskPriority]::Normal # Priorité normale par défaut
    $this.Tags = @() # Aucun tag par défaut
    $this.Description = "" # Pas de description par défaut
    $this.TimeSpent = [timespan]::Zero # Temps passé initialisé à zéro
    $this.CurrentStartTime = [datetime]::MinValue # Pas de temps de début actuel par défaut
    $this.DueDate = [datetime]::MinValue # Pas de date d'échéance par défaut
  }

  [string] ToString() {
    return $this.Title
  }
}

# Initialisation
function Initialize-TaskManager {
  try {
    $script:NextTaskId = 1

    if (Test-Path -Path $script:TaskFilePath) {
      $jsonContent = Get-Content -Path $script:TaskFilePath -Raw -ErrorAction Stop

      if ([string]::IsNullOrWhiteSpace($jsonContent)) {
        Write-Warning "Le fichier de tâches est vide. Initialisation avec une liste vide."
        $script:TaskList = @()
        Save-Tasks
        return
      }

      try {
        $jsonTasks = $jsonContent | ConvertFrom-Json -ErrorAction Stop
      } catch {
        Write-Warning "Fichier JSON corrompu ou invalide. Sauvegarde et réinitialisation..."
        $backupFile = "$script:TaskFilePath.backup"
        Copy-Item $script:TaskFilePath $backupFile -Force
        $script:TaskList = @()
        Save-Tasks
        return
      }

      $script:TaskList = @()

      if ($jsonTasks) {
        if ($jsonTasks -is [array]) {
          $taskArray = $jsonTasks
        } else {
          $taskArray = @($jsonTasks)
        }
      } else {
        $taskArray = @()
      }

      foreach ($jsonTask in $taskArray) {
        try {
          $task = [PSTask]::new()
          $task.Id = [int]$jsonTask.Id
          $task.Title = [string]$jsonTask.Title
          $task.CreatedAt = [datetime]$jsonTask.CreatedAt
          $task.DueDate = if ($jsonTask.DueDate -and $jsonTask.DueDate -ne "" -and $jsonTask.DueDate -ne $null) {
            [datetime]$jsonTask.DueDate
          } else {
            Get-Date
          }
          $task.Completed = [bool]$jsonTask.Completed
          $task.Priority = [TaskPriority]$jsonTask.Priority
          $task.Tags = if ($jsonTask.Tags) { @($jsonTask.Tags) } else { @() }
          $task.Description = if ($jsonTask.Description) { [string]$jsonTask.Description } else { "" }
          $task.TimeSpent = if ($jsonTask.TimeSpent) {
            [timespan]::Parse($jsonTask.TimeSpent)
          } else {
            [timespan]::Zero
          }

          $script:TaskList += $task

          if ($task.Id -ge $script:NextTaskId) {
            $script:NextTaskId = $task.Id + 1
          }
        } catch {
          Write-Warning "Erreur lors du chargement d'une tâche : $_"
          continue
        }
      }

      if ($script:TaskList.Count -gt 0) {
        $maxId = ($script:TaskList | Measure-Object -Property Id -Maximum).Maximum
        $script:NextTaskId = $maxId + 1
      } else {
        $script:NextTaskId = 1
      }

      Write-Verbose "Chargé $($script:TaskList.Count) tâches. Prochain ID de tâche : $script:NextTaskId"
    } else {
      Write-Verbose "Aucun fichier de tâches trouvé. Initialisation avec une liste vide."
      $script:TaskList = @()
    }
  } catch {
    Write-Warning "Erreur lors de l'initialisation : $_"
    Write-Warning "Réinitialisation avec une liste vide."
    $script:TaskList = @()
    $script:NextTaskId = 1
  }
}

# Fonction de sauvegarde des tâches
function Save-Tasks {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  try {
    if ($PSCmdlet.ShouldProcess("Fichier de tâches", "Sauvegarde")) {
      $taskDir = Split-Path $script:TaskFilePath -Parent
      if (-not (Test-Path $taskDir)) {
        New-Item -Path $taskDir -ItemType Directory -Force | Out-Null
      }

      # Préparation des données pour la sauvegarde
      $dataToSave = @()
      foreach ($task in $script:TaskList) {
        $taskData = @{
          Id = $task.Id
          Title = $task.Title
          CreatedAt = $task.CreatedAt.ToString("yyyy-MM-ddTHH:mm:ss") # Format ISO 8601
          DueDate = if ($task.DueDate -ne [datetime]::MinValue) { $task.DueDate.ToString("yyyy-MM-ddTHH:mm:ss") } else { "" }
          Completed = $task.Completed
          Priority = $task.Priority.ToString()
          Tags = $task.Tags
          Description = $task.Description
          TimeSpent = $task.TimeSpent.ToString()
        }
        $dataToSave += $taskData
    }

    $jsonContent = $dataToSave | ConvertTo-Json -Depth 5 -Compress:$false # Convertit en format JSON
    $jsonContent | Out-Fil $script:TaskFilePath -Encoding UTF8 -Force # Sauvegarde dans le fichier

    Write-Verbose "Sauvegardé $($script:TaskList.Count) tâches dans le fichier $script:TaskFilePath"
  }
  } catch {
    Write-Error "Erreur lors de la sauvegarde des tâches : $($_.Exception.Message)"
    Write-Error "Chemin du fichier : $script:TaskFilePath"
    Write-Error "Détails de l'erreur : $($_.Exception.ToString())"
  }
}
