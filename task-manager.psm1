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

  [bool] IsTimerRunning() {
    return $this.CurrentStartTime -ne [datetime]::MinValue
  }

  [void] StartTimer() {
    if (-not $this.IsTimerRunning()) {
      $this.CurrentStartTime = Get-Date
    }
  }

  [timespan] StopTimer() {
    $elapsed = [timespan]::Zero
    if ($this.IsTimerRunning()) {
      $elapsed = (Get-Date) - $this.CurrentStartTime
      $this.TimeSpent += $elapsed
      $this.CurrentStartTime = [datetime]::MinValue
    }
    return $elapsed
  }

  [bool] IsOverdue() {
    return ($this.DueDate -ne [datetime]::MinValue) -and ($this.DueDate -lt (Get-Date)) -and (-not $this.Completed)
  }

  [int] DaysUntilDue() {
    if ($this.DueDate -eq [datetime]::MinValue) {
      return 9999
    }
    $timeSpan = $this.DueDate - (Get-Date).Date
    return $timeSpan.Days
  }
}

# Initialisation
function Initialize-TaskManager {
  try {
    $script:NextTaskId = ($script:TaskList | Measure-Object -Property Id -Maximum | Select-Object -ExpandProperty Maximum) + 1
    
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

# Fonctions internes

function Find-PSTaskByIdOrTitle {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Identifier,

    [switch]$IncludeCompleted
  )

  $task = $null
  
  # Essayer de trouver par l'ID d'abord
  if ($Identifier -match '^\d+$') {
    $taskId = [int]$Identifier
    $task = $script:TaskList | Where-Object { $_.Id -eq $taskId }
  }

  # Si non trouvé par ID, chercher par titre
  if (-not $task) {
    $searchPool = $script:TaskList
    # Par défaut, on ne cherche que dans les tâches actives
    if (-not $IncludeCompleted) {
      $searchPool = $searchPool | Where-Object { -not $_.Completed }
    }

    # Retourner le premier résultat correspondant
    $task = $searchPool | Where-Object { $_.Description -eq $Identifier } | Select-Object -First 1
  }

  return $task
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


## Fonctions principales

#Fonction d'ajout d'une tâche
function Add-Task {
  [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName='Default')]
  [Alias('at')]
  param(
  [Parameter(Mandatory=$true, Position=0)]
  [ValidateNotNullOrEmpty()]
  [string]$Title, # Titre de la tâche (obligatoire & unique)
  
  [Parameter(ParameterSetName='WithDueDate')]
  [Parameter(ParameterSetName='Default')]
  $DueDate, # Date d'échéance de la tâche (optionnelle)
  
  [Parameter(ParameterSetName='Default')]
  [Parameter(ParameterSetName='WithDueDate')]
  [TaskPriority]$Priority = [TaskPriority]::Normal,
  
  [Parameter(ParameterSetName='Default')]
  [Parameter(ParameterSetName='WithDueDate')]
  [string[]]$Tags, # Liste de tags associés à la tâche (optionnelle)
  
  [Parameter(ParameterSetName='Default')]
  [Parameter(ParameterSetName='WithDueDate')]
  [string]$Description, # Description de la tâche (optionnelle)
  
  [Parameter(ParameterSetName='Default')]
  [switch]$DueTomorrow, # Indique si la tâche est due demain (optionnelle)
  
  [Parameter(ParameterSetName='Default')]
  [switch]$DueNextWeek, # Indique si la tâche est due la semaine prochaine (optionnelle)
  
  [Parameter(ParameterSetName='Default')]
  [switch]$NoDefaultDueDate
  )
  
  $existingTask = $script:TaskList | Where-Object {
    $_.Title -eq $Title -and -not $_.Completed
  }
  
  if ($existingTask) {
    Write-Error "Une tâche avec le titre '$Title' existe déjà et n'est pas terminée."
    return $existingTask
  }
  
  $task = [PSTask]::new()
  $task.Id = $script:NextTaskId++
  $task.Title = $Title
  
  if ($DueDate) {
    try {
      $task.DueDate = [datetime]$DueDate
    } catch {
      Write-Warning "Format de la date invalide."
      return
    }
  } elseif ($DueTomorrow) {
    $task.DueDate = (Get-Date).AddDays(1).Date
  } elseif ($DueNextWeek) {
    $task.DueDate = (Get-Date).AddDays(7).Date
  } elseif (-note $NoDefaultDueDate) {
    $task.DueDate = (Get-Date).Date # Date d'échéance par défaut à aujourd'hui
  }
  
  $task.Priority = $Priority
  if ($Tags) { $task.Tags = $Tags }
  if ($Description) { $task.Description = $Description }
  
  if ($PSCmdlet.ShouldProcess($Title, "Ajout d'une tâche")) {
    $script:TaskList = @($script:TaskList) + @($task) # Ajoute la tâche à la liste
    Save-Tasks
    
    $dueInfo = if ($task.DueDate) {
      " (échéance : $($task.DueDate.ToString('dd/MM/yyyy')))"
    } else {
      " (aucune échéance)"
    }
    
    Write-Host "✅ Tâche #$($task.Id) ajoutée : " -NoNewline -ForegroundColor Green
    Write-Host $Description -NoNewline -ForegroundColor White
    Write-Host $dueInfo -ForegroundColor DarkGray
    return $task
  }
}


# Fonction de suppression d'une tâche
function Remove-Task {
  [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName='ByIdOrDescription')]
  [Alias('rt')]
  param(
  [Parameter(Mandatory=$true, Position=0, ParameterSetName='ByIdOrDescription')]
  [string]$IdOrDescription,
  
  [Parameter(ParameterSetName='ByIdOrDescription')]
  [switch]$Force,
  
  [Parameter(ParameterSetName='ByIdOrDescription')]
  [switch]$CompletedOnly
  )
  
  $isId = $false
  $id = 0
  if ([int]::TryParse($IdOrDescription, [ref]$id)) {
    $isId = $true
  }
  
  if ($isId) {
    $task = $script:TaskList | Where-Object { $_.Id -eq $id }
    if (-not $task) {
      Write-Warning "Aucune tâche trouvée avec l'ID '$id'"
      return
    }
    
    if (-not $task.Completed -and -not $Force) {
      $confirmation = Read-Host "La tâche n'est pas complétée. Supprimer quand même ? (O/N)"
      if ($confirmation -ne 'O') {
        return $task
      }
    }
    
    if ($PSCmdlet.ShouldProcess($task.Description, "Suppression de tâche")) {
      $script:TaskList = $script:TaskList | Where-Object { $_.Id -ne $id }
      Save-Tasks
      Write-Host "🗑️ Tâche #$($task.Id) supprimée : $($task.Description)" -ForegroundColor Yellow
      return $task
    }
  }
  else {
    $filter = { $_.Description -eq $IdOrDescription }
    if ($CompletedOnly) {
      $filter = { $_.Description -eq $IdOrDescription -and $_.Completed }
    }
    
    $matchingTasks = $script:TaskList | Where-Object $filter
    
    if (-not $matchingTasks) {
      Write-Warning "Aucune tâche trouvée avec cette description"
      return
    }
    
    if ($matchingTasks.Count -gt 1 -and -not $Force) {
      Write-Host "⚠️ Plusieurs tâches trouvées avec cette description :" -ForegroundColor Yellow
      $matchingTasks | Format-Table Id, Description, Priority, Completed -AutoSize
      Write-Host "Utilisez -Force pour toutes supprimer ou spécifiez l'ID"
      return
    }
    
    if ($PSCmdlet.ShouldProcess($IdOrDescription, "Suppression de tâche(s)")) {
      if ($Force) {
        $script:TaskList = $script:TaskList | Where-Object { $_.Description -ne $IdOrDescription }
        $count = $matchingTasks.Count
      } else {
        $taskToRemove = $matchingTasks | Where-Object { -not $_.Completed } | Select-Object -First 1
        if (-not $taskToRemove) {
          $taskToRemove = $matchingTasks | Select-Object -First 1
        }
        $script:TaskList = $script:TaskList | Where-Object { $_.Id -ne $taskToRemove.Id }
        $count = 1
      }
      
      Save-Tasks
      Write-Host "🗑️ Supprimé $count tâche(s) : $IdOrDescription" -ForegroundColor Yellow
      return $matchingTasks
    }
  }
}

# Fonction d'affichage des tâches
function Get-Tasks {
  [CmdletBinding()]
  [Alias('gt')]
  [OutputType([PSTask])]
  param(
  [switch]$Completed,
  [switch]$Pending,
  [string]$Tag,
  [TaskPriority]$Priority,
  [int]$Limit,
  [switch]$Overdue,
  [switch]$DueToday,
  [switch]$DueThisWeek,
  [switch]$PassThru,
  [string]$Filter,
  [ValidateSet('Priority', 'DueDate', 'Created', 'Description')]
  [string]$SortBy = 'Priority',
  [switch]$Descending
  )
  
  $tasks = $script:TaskList
  
  if ($Completed) { $tasks = $tasks | Where-Object { $_.Completed } }
  if ($Pending) { $tasks = $tasks | Where-Object { -not $_.Completed } }
  if ($Tag) { $tasks = $tasks | Where-Object { $_.Tags -contains $Tag } }
  if ($Priority) { $tasks = $tasks | Where-Object { $_.Priority -eq $Priority } }
  if ($Overdue) { $tasks = $tasks | Where-Object { $_.IsOverdue() } }
  if ($DueToday) { $tasks = $tasks | Where-Object { $_.DueDate -and $_.DueDate.Date -eq (Get-Date).Date } }
  if ($DueThisWeek) { 
    $endOfWeek = (Get-Date).AddDays(7).Date
    $tasks = $tasks | Where-Object { $_.DueDate -and $_.DueDate.Date -le $endOfWeek -and $_.DueDate.Date -ge (Get-Date).Date }
  }
  if ($Filter) {
    $tasks = $tasks | Where-Object { 
      $_.Description -like "*$Filter*" -or 
      $_.Tags -contains $Filter -or
      $_.Notes -like "*$Filter*"
    }
  }
  
  $sortParams = @{
    Property = $SortBy
    Descending = $Descending
  }
  $tasks = $tasks | Sort-Object @sortParams
  
  if ($Limit -gt 0) { $tasks = $tasks | Select-Object -First $Limit }
  
  if ($PassThru) {
    return $tasks
  }
  
  if (-not $tasks) {
    Write-Host "Aucune tâche trouvée" -ForegroundColor Yellow
    return
  }
  
  # Définition des colonnes avec mise en forme améliorée
  $tableFormat = @(
  @{Label="ID"; Expression={$_.Id}; Alignment="Right"},
  @{Label="✓"; Expression={if ($_.Completed) { "✓" } else { " " }}; Alignment="Center"},
  @{Label="Priorité"; Expression={$_.Priority}; Alignment="Left"},
  @{Label="Description"; Expression={$_.Description}; Alignment="Left"},
  @{Label="Échéance"; Expression={
    if ($_.IsOverdue()) { "⚠️ En retard ($(-$_.DaysUntilDue())j)" }
    elseif ($_.DueDate.Date -eq (Get-Date).Date) { "🕒 Aujourd'hui" }
    elseif ($_.DueDate -ne [datetime]::MinValue) { "📅 Dans $($_.DaysUntilDue())j" }
    else { "∞ Aucune" }
  }; Alignment="Left"},
  @{Label="Tags"; Expression={if ($_.Tags) { "🏷️ " + ($_.Tags -join ', ') } else { "" }}; Alignment="Left"},
  @{Label="Temps"; Expression={
    $timeInfo = $_.TimeSpent.ToString("hh\:mm\:ss")
    if ($_.IsTimerRunning()) {
      $currentElapsed = (Get-Date) - $_.CurrentStartTime
      $total = $_.TimeSpent + $currentElapsed
      "⏱️ $($total.ToString('hh\:mm\:ss'))"
    }
    elseif ($_.TimeSpent -gt [timespan]::Zero) {
      "⏱️ $timeInfo"
    } 
    else { "" }
  }; Alignment="Right"}
  )
  
  # Affichage avec Format-Table amélioré
  $tasks | Format-Table -Property $tableFormat -AutoSize -Wrap |
  Out-String -Width ($Host.UI.RawUI.BufferSize.Width - 1) |
  ForEach-Object { $_.TrimEnd() }
}


function Complete-Task {
  [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName='ByIdOrDescription')]
  [Alias('ct')]
  param(
  [Parameter(Mandatory=$true, Position=0, ParameterSetName='ByIdOrDescription')]
  [string]$IdOrDescription,
  
  [Parameter(ParameterSetName='ByIdOrDescription')]
  [switch]$All
  )
  
  $isId = $false
  $id = 0
  if ([int]::TryParse($IdOrDescription, [ref]$id)) {
    $isId = $true
  }
  
  if ($isId) {
    $task = $script:TaskList | Where-Object { $_.Id -eq $id }
    
    if (-not $task) {
      Write-Warning "Aucune tâche trouvée avec l'ID '$id'"
      return
    }
    
    if ($task.Completed) {
      Write-Warning "La tâche est déjà complétée"
      return $task
    }
    
    if ($PSCmdlet.ShouldProcess($task.Description, "Marquer comme complétée")) {
      # Correction: Arrêter le timer automatiquement si en cours
      if ($task.IsTimerRunning()) {
        $elapsed = $task.StopTimer()
        Write-Host "⏱️ Timer automatiquement arrêté (temps écoulé: $($elapsed.ToString('hh\:mm\:ss')))" -ForegroundColor DarkGray
      }
      
      $task.Completed = $true
      Save-Tasks
      Write-Host "✅ Tâche #$($task.Id) complétée : $($task.Description)" -ForegroundColor Green
      return $task
    }
  }
  else {
    $tasks = $script:TaskList | Where-Object { 
      $_.Description -eq $IdOrDescription -and -not $_.Completed 
    }
    
    if (-not $tasks) {
      Write-Warning "Aucune tâche active trouvée avec cette description"
      return
    }
    
    if ($tasks.Count -gt 1 -and -not $All) {
      Write-Host "⚠️ Plusieurs tâches trouvées avec cette description :" -ForegroundColor Yellow
      $tasks | Format-Table Id, Description, Priority, DueDate -AutoSize
      Write-Host "Utilisez -All pour toutes marquer comme complétées ou spécifiez l'ID"
      return
    }
    
    if ($PSCmdlet.ShouldProcess($IdOrDescription, "Marquer comme complétée(s)")) {
      $tasks | ForEach-Object { 
        # Correction: Arrêter le timer pour chaque tâche si nécessaire
        if ($_.IsTimerRunning()) {
          $elapsed = $_.StopTimer()
          Write-Host "⏱️ Timer automatiquement arrêté pour '$($_.Description)' (temps écoulé: $($elapsed.ToString('hh\:mm\:ss')))" -ForegroundColor DarkGray
        }
        $_.Completed = $true 
      }
      Save-Tasks
      $count = $tasks.Count
      Write-Host "✅ $count tâche(s) complétée(s) : $IdOrDescription" -ForegroundColor Green
      return $tasks
    }
  }
}

# Fonction de mise à jour d'une tâche
function Update-Task {
  [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName='ByIdOrDescription')]
  [Alias('ut')]
  param(
  [Parameter(Mandatory=$true, Position=0, ParameterSetName='ByIdOrDescription')]
  [string]$IdOrDescription,
  
  [string]$NewDescription,
  
  [datetime]$DueDate,
  
  [TaskPriority]$Priority,
  
  [string[]]$Tags,
  
  [string]$Notes,
  
  [switch]$ClearDueDate,
  
  [switch]$ClearTags,
  
  [switch]$ClearNotes
  )
  
  $isId = $false
  $id = 0
  if ([int]::TryParse($IdOrDescription, [ref]$id)) {
    $isId = $true
  }
  
  $task = $null
  if ($isId) {
    $task = $script:TaskList | Where-Object { $_.Id -eq $id }
    if (-not $task) {
      Write-Warning "Aucune tâche trouvée avec l'ID '$id'"
      return
    }
  }
  else {
    $task = $script:TaskList | Where-Object { 
      $_.Description -eq $IdOrDescription -and -not $_.Completed 
    } | Select-Object -First 1
    
    if (-not $task) {
      Write-Warning "Aucune tâche active trouvée avec la description '$IdOrDescription'"
      return
    }
  }
  
  if ($NewDescription -and $NewDescription -ne $task.Description) {
    $existingTask = $script:TaskList | Where-Object { 
      $_.Description -eq $NewDescription -and -not $_.Completed -and $_.Id -ne $task.Id
    }
    
    if ($existingTask) {
      Write-Warning "Une tâche active avec la description '$NewDescription' existe déjà (ID: $($existingTask.Id))"
      return
    }
  }
  
  if ($PSCmdlet.ShouldProcess($task.Description, "Mise à jour de tâche")) {
    $oldDescription = $task.Description
    
    if ($NewDescription) { $task.Description = $NewDescription }
    if ($PSBoundParameters.ContainsKey('DueDate')) { $task.DueDate = $DueDate }
    if ($ClearDueDate) { $task.DueDate = [datetime]::MinValue }
    if ($Priority) { $task.Priority = $Priority }
    if ($Tags) { $task.Tags = $Tags }
    if ($ClearTags) { $task.Tags = @() }
    if ($Notes) { $task.Notes = $Notes }
    if ($ClearNotes) { $task.Notes = "" }
    
    Save-Tasks
    
    $displayDescription = if ($NewDescription) { $NewDescription } else { $oldDescription }
    Write-Host "✏️ Tâche #$($task.Id) mise à jour : $displayDescription" -ForegroundColor Cyan
    return $task
  }
}

# Fonction Complémentaires
function Get-TasksSummary {
  [CmdletBinding()]
  [Alias('gts')]
  param(
  [switch]$Detailed
  )
  
  $total = $script:TaskList.Count
  $completed = ($script:TaskList | Where-Object { $_.Completed }).Count
  $pending = $total - $completed
  
  if ($total -eq 0) {
    Write-Host "Aucune tâche à l'horizon..." -ForegroundColor Yellow
    return
  }
  
  Write-Host "📊 Statistiques des tâches" -ForegroundColor Magenta
  Write-Host "Total: $total" -ForegroundColor White
  Write-Host "Complétées: $completed ($([math]::Round($completed/$total*100))%)" -ForegroundColor Green
  Write-Host "En attente: $pending ($([math]::Round($pending/$total*100))%)" -ForegroundColor Yellow
  
  if ($Detailed) {
    Write-Host ""
    Write-Host "📌 Répartition par priorité :" -ForegroundColor Cyan
    [Enum]::GetValues([TaskPriority]) | ForEach-Object {
      $pri = $_
      $count = ($script:TaskList | Where-Object { $_.Priority -eq $pri -and -not $_.Completed }).Count
      if ($count -gt 0) {
        Write-Host "$($pri.ToString().PadRight(7)): $count" -ForegroundColor $script:Colors[$pri.ToString()]
      }
    }
  }
  
  $urgent = $script:TaskList | Where-Object { $_.Priority -eq "Urgent" -and -not $_.Completed }
  $overdue = $script:TaskList | Where-Object { $_.IsOverdue() }
  
  if ($urgent.Count -gt 0) {
    Write-Host ""
    Write-Host "⚠️ Tâches urgentes:" -ForegroundColor Red
    $urgent | Format-Table -AutoSize @(
    @{Label="ID"; Expression={$_.Id}; Alignment="Right"},
    @{Label="Description"; Expression={$_.Description}; Alignment="Left"},
    @{Label="Échéance"; Expression={$_.DueDate.ToString('dd/MM/yyyy')}; Alignment="Left"}
    ) | Out-String -Width ($Host.UI.RawUI.BufferSize.Width - 1)
  }
  if ($overdue.Count -gt 0) {
    Write-Host ""
    Write-Host "⏰ Tâches en retard:" -ForegroundColor Red
    $overdue | Format-Table -AutoSize @(
    @{Label="ID"; Expression={$_.Id}; Alignment="Right"},
    @{Label="Description"; Expression={$_.Description}; Alignment="Left"},
    @{Label="En retard de"; Expression={"$(-$_.DaysUntilDue()) jours"}; Alignment="Right"}
    ) | Out-String -Width ($Host.UI.RawUI.BufferSize.Width - 1)
  }
}


function Clear-CompletedTasks {
  [CmdletBinding(SupportsShouldProcess)]
  [Alias('cct')]
  param(
  [switch]$Archive
  )
  
  $completed = $script:TaskList | Where-Object { $_.Completed }
  if (-not $completed) {
    Write-Host "Aucune tâche complétée à supprimer" -ForegroundColor Yellow
    return
  }
  
  if ($Archive) {
    try {
      $archiveData = @()
      if (Test-Path $script:ArchiveFile) {
        $archiveData = Get-Content $script:ArchiveFile -Raw | ConvertFrom-Json
      }
      $archiveData += $completed
      $archiveData | ConvertTo-Json -Depth 5 | Out-File $script:ArchiveFile -Encoding UTF8 -Force
      Write-Host "📦 Archivé $($completed.Count) tâches complétées" -ForegroundColor Cyan
    }
    catch {
      Write-Warning "Erreur lors de l'archivage : $_"
      return
    }
  }
  
  if ($PSCmdlet.ShouldProcess("$($completed.Count) tâches", "Suppression")) {
    $script:TaskList = $script:TaskList | Where-Object { -not $_.Completed }
    Save-Tasks
    Write-Host "🗑️ Supprimé $($completed.Count) tâches complétées" -ForegroundColor Green
  }
}

function Get-TaskDueSoon {
  [CmdletBinding()]
  [Alias('gtds')]
  param(
  [int]$Days = 7
  )
  
  $endDate = (Get-Date).AddDays($Days).Date
  $tasks = $script:TaskList | Where-Object { 
    -not $_.Completed -and 
    $_.DueDate -and 
    $_.DueDate -le $endDate -and 
    $_.DueDate -ge (Get-Date).Date
  } | Sort-Object DueDate
  
  if (-not $tasks) {
    Write-Host "Aucune tâche à échéance dans les $Days jours" -ForegroundColor Yellow
    return
  }
  
  Write-Host "📅 Tâches à échéance dans les $Days jours :" -ForegroundColor Cyan
  
  $tasks | Format-Table -AutoSize @(
  @{Label="Échéance"; Expression={$_.DueDate.ToString('dd/MM/yyyy')}; Alignment="Left"},
  @{Label="Priorité"; Expression={$_.Priority}; Alignment="Left"},
  @{Label="Description"; Expression={$_.Description}; Alignment="Left"},
  @{Label="Délai"; Expression={
    if ($_.DaysUntilDue() -eq 0) { "🕒 Aujourd'hui" }
    else { "⏳ Dans $($_.DaysUntilDue()) jours" }
  }; Alignment="Left"}
  ) | Out-String -Width ($Host.UI.RawUI.BufferSize.Width - 1)
}

function Send-TaskReminder {
  [CmdletBinding()]
  param(
  [int]$DaysAhead = 1
  )
  
  $reminderDate = (Get-Date).AddDays($DaysAhead).Date
  $tasks = $script:TaskList | Where-Object { 
    -not $_.Completed -and 
    $_.DueDate -and 
    $_.DueDate.Date -eq $reminderDate 
  }
  
  if (-not $tasks) {
    Write-Host "Aucune tâche à échéance demain" -ForegroundColor Yellow
    return
  }
  
  Write-Host "🔔 Rappel : Tâches à échéance le $($reminderDate.ToString('dd/MM/yyyy'))" -ForegroundColor Magenta
  $tasks | ForEach-Object {
    Write-Host "  - $($_.Description) (Priorité: $($_.Priority))" -ForegroundColor White
  }
}

function Start-TaskTimer {
  [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName='ByDescription')]
  [Alias('lt')]  # Alias pour "launch-task"
  param(
  [Parameter(Mandatory=$true, Position=0, ParameterSetName='ByDescription')]
  [string]$Description,
  
  [Parameter(Mandatory=$true, ParameterSetName='ById')]
  [string]$Id
  )
  
  if ($PSCmdlet.ParameterSetName -eq 'ById') {
    # ✅ Conversion en int pour la comparaison
    $taskId = 0
    if ([int]::TryParse($Id, [ref]$taskId)) {
      $task = $script:TaskList | Where-Object { $_.Id -eq $taskId }
    } else {
      Write-Warning "ID invalide : '$Id'. Veuillez utiliser un nombre entier."
      return
    }
  }
  else {
    $task = $script:TaskList | Where-Object { 
      $_.Description -eq $Description -and -not $_.Completed 
    } | Select-Object -First 1
  }
  
  if (-not $task) {
    if ($PSCmdlet.ParameterSetName -eq 'ById') {
      Write-Warning "Aucune tâche trouvée avec l'ID '$Id'"
    } else {
      Write-Warning "Aucune tâche active trouvée avec la description '$Description'"
    }
    return
  }
  
  if ($task.IsTimerRunning()) {
    Write-Warning "Un chrono est déjà en cours pour cette tâche"
    return $task
  }
  
  if ($PSCmdlet.ShouldProcess($task.Description, "Démarrer le chrono")) {
    $task.StartTimer()
    Save-Tasks
    
    Write-Host "⏱️ Chrono démarré pour la tâche : " -NoNewline -ForegroundColor Cyan
    Write-Host $task.Description -ForegroundColor White
    return $task
  }
}

function Stop-TaskTimer {
  [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName='ByDescription')]
  [Alias('st')]  # Alias pour "stop-task"
  param(
  [Parameter(Mandatory=$true, Position=0, ParameterSetName='ByDescription')]
  [string]$Description,
  
  [Parameter(Mandatory=$true, ParameterSetName='ById')]
  [string]$Id
  )
  
  $task = Find-PSTaskByIdOrDescription -Identifier $IdOrDescription
  
  if (-not $task) {
    Write-Warning "Aucune tâche active trouvée avec l'identifiant ou la description '$IdOrDescription'"
    return
  }
  
  if (-not $task.IsTimerRunning()) {
    Write-Warning "Aucun chrono en cours pour cette tâche"
    return $task
  }
  
  if ($PSCmdlet.ShouldProcess($task.Description, "Arrêter le chrono")) {
    $elapsed = $task.StopTimer() # La logique est maintenant dans la classe !
    Save-Tasks
    
    Write-Host "⏱️ Chrono arrêté pour la tâche : $($task.Description) (temps écoulé: $($elapsed.ToString('hh\:mm\:ss')))" -ForegroundColor Cyan
    Write-Host "  Temps total passé sur cette tâche: $($task.TimeSpent.ToString('hh\:mm\:ss'))" -ForegroundColor DarkGray
    return $task
  }
}

function Get-TaskTime {
  [CmdletBinding(DefaultParameterSetName='ByDescription')]
  [Alias('gtt')]
  param(
  [Parameter(Position=0, ParameterSetName='ByDescription')]
  [string]$Description,
  
  [Parameter(Mandatory=$true, ParameterSetName='ById')]
  [string]$Id,
  
  [switch]$All
  )
  
  if ($All) {
    if ($script:TaskList.Count -eq 0) {
      Write-Host "Aucune tâche enregistrée" -ForegroundColor Yellow
      return
    }
    
    $totalTime = [timespan]::Zero
    
    $tasksWithTime = $script:TaskList | Where-Object { $_.TimeSpent -gt [timespan]::Zero -or $_.IsTimerRunning() }
    if ($tasksWithTime.Count -eq 0) {
      Write-Host "Aucune donnée de temps enregistrée pour les tâches" -ForegroundColor Yellow
      return
    }
    
    Write-Host "📊 Temps passé sur toutes les tâches :" -ForegroundColor Cyan
    
    $tasksWithTime | Sort-Object -Property TimeSpent -Descending | Format-Table -AutoSize @(
    @{Label="Description"; Expression={$_.Description}; Alignment="Left"},
    @{Label="Temps Passé"; Expression={
      $timeInfo = $_.TimeSpent.ToString("hh\:mm\:ss")
      if ($_.IsTimerRunning()) {
        $currentElapsed = (Get-Date) - $_.CurrentStartTime
        $total = $_.TimeSpent + $currentElapsed
        "⏱️ $($total.ToString('hh\:mm\:ss'))"
      } else {
        "⏱️ $timeInfo"
      }
    }; Alignment="Right"}
    ) | Out-String -Width ($Host.UI.RawUI.BufferSize.Width - 1)
    
    $totalTime = [timespan]::Zero
    foreach($task in $tasksWithTime){ $totalTime += $task.TimeSpent }
    
    Write-Host "⏱️ Temps total enregistré : $($totalTime.ToString('hh\:mm\:ss'))" -ForegroundColor Green
    return
  }
  
  if ($PSCmdlet.ParameterSetName -eq 'ById') {
    $task = $script:TaskList | Where-Object { $_.Id -eq [int]$Id }
    if (-not $task) {
      Write-Warning "Aucune tâche trouvée avec l'ID '$Id'"
      return
    }
  }
  else {
    if (-not $Description) {
      $task = $script:TaskList | Where-Object { $_.IsTimerRunning() } | Select-Object -First 1
      if (-not $task) {
        Write-Host "Aucune tâche en cours actuellement" -ForegroundColor Yellow
        return
      }
    }
    else {
      $task = $script:TaskList | Where-Object { $_.Description -eq $Description } | Select-Object -First 1
      if (-not $task) {
        Write-Warning "Aucune tâche trouvée avec cette description"
        return
      }
    }
  }
  
  $timeInfo = $task.TimeSpent.ToString("hh\:mm\:ss")
  if ($task.IsTimerRunning()) {
    $currentElapsed = (Get-Date) - $task.CurrentStartTime
    $total = $task.TimeSpent + $currentElapsed
    $timeInfo = "$($total.ToString('hh\:mm\:ss')) (en cours)"
  }
  
  Write-Host "⏱️ Temps passé sur '$($task.Description)': $timeInfo" -ForegroundColor Cyan
  return
}

# Initialiser le gestionnaire au chargement
Initialize-TaskManager

# Export des fonctions
Export-ModuleMember -Function Add-Task, Get-Tasks, Complete-Task, Remove-Task, Update-Task, 
    Get-TasksSummary, Clear-CompletedTasks, Get-TaskDueSoon, Send-TaskReminder,
    Start-TaskTimer, Stop-TaskTimer, Get-TaskTime

# Export des alias
Export-ModuleMember -Alias at, gt, ct, rt, ut, gts, cct, gtds, lt, st, gtt
