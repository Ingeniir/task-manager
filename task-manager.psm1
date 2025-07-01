<#
.SYNOPSIS
    Gestionnaire de tâches PowerShell avancé
.DESCRIPTION
    Module complet pour gérer des tâches avec sauvegarde JSON, rappels, statistiques et fonctions avancées
.EXAMPLE
    PS> Add-Task "Préparer la réunion" -Due (Get-Date).AddDays(2) -Priority High -Tags "Réunion","Important"
    PS> Get-Tasks -Pending | Where DueDate -LT (Get-Date).AddDays(7) | Complete-Task
.NOTES
    Version: 1.0
    Auteur : Hoareau Cédric
    Date   : $(Get-Date -Format 'yyyy-MM-dd')
#>

# Configuration
$script:TaskFile = Join-Path -Path $env:USERPROFILE -ChildPath "ps_tasks.json"
$script:ArchiveFile = Join-Path -Path $env:USERPROFILE -ChildPath "ps_tasks_archive.json"
$script:TaskList = @()
$script:NextTaskId = 1
$script:Colors = @{
    Low = "DarkGray"
    Normal = "White"
    High = "Yellow"
    Urgent = "Red"
    Completed = "Green"
    Overdue = "Red"
    DueToday = "Yellow"
    Future = "Cyan"
}

enum TaskPriority {
    Low
    Normal
    High
    Urgent
}

class PSTask {
    [int]$Id # Identifiant unique de la tâche
    [ValidateNotNullOrEmpty()]
    [string]$Description # Description de la tâche
    [datetime]$Created # Date de création de la tâche
    [datetime]$DueDate  # Date d'échéance de la tâche, peut être $null
    [bool]$Completed # Indique si la tâche est complétée
    [TaskPriority]$Priority # Priorité de la tâche
    [string[]]$Tags # Liste de tags associés à la tâche
    [string]$Notes # Notes supplémentaires pour la tâche
    [timespan]$TimeSpent # Temps passé sur la tâche
    [datetime]$CurrentStartTime # Heure de début du timer pour la tâche, peut être MinValue si pas en cours

    # Constructeur
    PSTask() {
        $this.Created = Get-Date # Date de création par défaut
        $this.Completed = $false # Tâche non complétée par défaut
        $this.Priority = [TaskPriority]::Normal # Priorité normale par défaut
        $this.Tags = @() # Aucun tag par défaut
        $this.Notes = "" # Pas de notes par défaut
        $this.TimeSpent = [timespan]::Zero # Temps passé initialisé à zéro
        $this.CurrentStartTime = [datetime]::MinValue # Timer non démarré par défaut
        $this.DueDate = [datetime]::MinValue  # Date d'échéance par défaut
    }

    # Méthode utilisé pour vérifier si la tâche est en retard
    [bool] IsOverdue() {
        return $this.DueDate -ne [datetime]::MinValue -and $this.DueDate -lt (Get-Date).Date -and -not $this.Completed
    }

    # Méthode pour vérifier si la tâche est due aujourd'hui
    [int] DaysUntilDue() {
        if ($this.DueDate -eq [datetime]::MinValue) { return [int]::MaxValue }
        return [math]::Ceiling(($this.DueDate - (Get-Date)).TotalDays)
    }

    # Méthode pour vérifier si le timer est en cours
    [bool] IsTimerRunning() {
        return $this.CurrentStartTime -ne [datetime]::MinValue
    }

    # Méthodes pour démarrer le timer
    [void] StartTimer() {
        if (-not $this.IsTimerRunning()) {
            $this.CurrentStartTime = Get-Date
        }
    }

    # Méthodes pour arrêter le timer et retourner le temps écoulé
    [timespan] StopTimer() {
        if ($this.IsTimerRunning()) {
            $elapsed = (Get-Date) - $this.CurrentStartTime
            $this.TimeSpent += $elapsed
            $this.CurrentStartTime = [datetime]::MinValue
            return $elapsed
        }
        return [timespan]::Zero
    }

    # Méthode qui renvoie la description de la tâche
    [string] ToString() {
        return $this.Description
    }
}

# Initialisation
function Initialize-TaskManager {
    try {
        $script:NextTaskId = 1  # Réinitialise l'ID de la prochaine tâche
        
        if (Test-Path $script:TaskFile) {  # Vérifie si le fichier de tâches existe
            $jsonContent = Get-Content $script:TaskFile -Raw -ErrorAction Stop
            
            if ([string]::IsNullOrWhiteSpace($jsonContent)) {
                # Fichier vide : on initialise une nouvelle liste
                Write-Warning "Le fichier de tâches est vide, initialisation d'une nouvelle liste"
                $script:TaskList = @()
                Save-Tasks
                return
            }
            
            try {
                # Tente de convertir le contenu JSON en objets PowerShell
                $jsonTasks = $jsonContent | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                # Si le JSON est corrompu, on sauvegarde le fichier et on réinitialise
                Write-Warning "Fichier JSON corrompu. Sauvegarde et réinitialisation..."
                $backupFile = "$script:TaskFile.backup"
                Copy-Item $script:TaskFile $backupFile -Force
                $script:TaskList = @()
                Save-Tasks
                return
            }
            
            $script:TaskList = @()
            
            # Si des tâches existent, on les charge dans la liste
            if ($jsonTasks) {
                if ($jsonTasks -is [array]) {
                    $tasksArray = $jsonTasks
                } else {
                    $tasksArray = @($jsonTasks)
                }
            } else {
                $tasksArray = @()
            }
            
            foreach ($jsonTask in $tasksArray) {
                try {
                    # Création d'une instance PSTask à partir des données JSON
                    $task = [PSTask]::new()
                    $task.Id = [int]$jsonTask.Id
                    $task.Description = [string]$jsonTask.Description
                    $task.Created = [datetime]$jsonTask.Created
                    $task.DueDate = if ($jsonTask.DueDate -and $jsonTask.DueDate -ne "" -and $jsonTask.DueDate -ne $null) { 
                        [datetime]$jsonTask.DueDate 
                    } else { 
                        Get-Date
                    }
                    $task.Completed = [bool]$jsonTask.Completed
                    $task.Priority = [TaskPriority]$jsonTask.Priority
                    $task.Tags = if ($jsonTask.Tags) { @($jsonTask.Tags) } else { @() }
                    $task.Notes = if ($jsonTask.Notes) { $jsonTask.Notes } else { "" }
                    $task.TimeSpent = if ($jsonTask.TimeSpent) { 
                        [timespan]::Parse($jsonTask.TimeSpent) 
                    } else { 
                        [timespan]::Zero 
                    }
                    $script:TaskList += $task
                    
                    # Met à jour le prochain ID si besoin
                    if ($task.Id -ge $script:NextTaskId) {
                        $script:NextTaskId = $task.Id + 1
                    }
                }
                catch {
                    Write-Warning "Erreur lors du chargement d'une tâche : $_"
                    continue
                }
            }
            
            # Recalcule le prochain ID de tâche
            if ($script:TaskList.Count -gt 0) {
                $maxId = ($script:TaskList | Measure-Object -Property Id -Maximum).Maximum
                $script:NextTaskId = $maxId + 1
            } else {
                $script:NextTaskId = 1
            }
            
            Write-Verbose "Chargé $($script:TaskList.Count) tâches. Prochain ID: $script:NextTaskId"
        } else {
            # Aucun fichier trouvé : on part d'une liste vide
            Write-Verbose "Aucun fichier de tâches trouvé, création d'une nouvelle liste"
            $script:TaskList = @()
        }
    }
    catch {
        # Gestion des erreurs globales
        Write-Warning "Erreur lors de l'initialisation : $_"
        Write-Warning "Réinitialisation avec une liste vide"
        $script:TaskList = @()
        $script:NextTaskId = 1
    }
}

# Sauvegarde des tâches
function Save-Tasks {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    
    try {
        # Vérifie si l'action doit être effectuée (supporte -WhatIf)
        if ($PSCmdlet.ShouldProcess("Fichier de tâches", "Sauvegarde")) {
            $taskDir = Split-Path $script:TaskFile -Parent
            # Crée le dossier de sauvegarde si nécessaire
            if (-not (Test-Path $taskDir)) {
                New-Item -Path $taskDir -ItemType Directory -Force | Out-Null # Créer le répertoire si nécessaire
            }
            
            # Prépare les données à sauvegarder dans un tableau d'objets simples
            $dataToSave = @()
            foreach ($task in $script:TaskList) {
                $taskData = @{
                    Id = $task.Id
                    Description = $task.Description
                    Created = $task.Created.ToString('yyyy-MM-ddTHH:mm:ss')
                    DueDate = if ($task.DueDate -ne [datetime]::MinValue) { $task.DueDate.ToString('yyyy-MM-ddTHH:mm:ss') } else { $null }
                    Completed = $task.Completed
                    Priority = $task.Priority.ToString()
                    Tags = $task.Tags
                    Notes = $task.Notes
                    TimeSpent = $task.TimeSpent.ToString()
                }
                $dataToSave += $taskData
            }
            
            # Convertit les données en JSON et les écrit dans le fichier
            $jsonContent = $dataToSave | ConvertTo-Json -Depth 5 -Compress:$false # Convertir en JSON avec une profondeur suffisante
            $jsonContent | Out-File $script:TaskFile -Encoding UTF8 -Force # Sauvegarde le contenu JSON
            
            Write-Verbose "Sauvegardé $($script:TaskList.Count) tâches dans $script:TaskFile"
        }
    }
    catch {
        # Gestion des erreurs lors de la sauvegarde
        Write-Error "Erreur lors de la sauvegarde des tâches : $($_.Exception.Message)"
        Write-Error "Chemin du fichier : $script:TaskFile"
        Write-Error "Détails de l'erreur : $($_.Exception.ToString())"
    }
}

## Fonctions principales

function Add-Task {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName='Default')]
    [Alias('at')]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [string]$Description,
        
        [Parameter(ParameterSetName='WithDueDate')]
        [Parameter(ParameterSetName='Default')]
        $DueDate,
        
        [Parameter(ParameterSetName='Default')]
        [Parameter(ParameterSetName='WithDueDate')]
        [TaskPriority]$Priority = [TaskPriority]::Normal,
        
        [Parameter(ParameterSetName='Default')]
        [Parameter(ParameterSetName='WithDueDate')]
        [string[]]$Tags,
        
        [Parameter(ParameterSetName='Default')]
        [Parameter(ParameterSetName='WithDueDate')]
        [string]$Notes,
        
        [Parameter(ParameterSetName='Default')]
        [switch]$DueTomorrow,
        
        [Parameter(ParameterSetName='Default')]
        [switch]$DueNextWeek,
        
        [Parameter(ParameterSetName='Default')]
        [switch]$NoDefaultDueDate 
    )

    # Vérifie si une tâche active avec la même description existe déjà
    $existingTask = $script:TaskList | Where-Object { 
        $_.Description -eq $Description -and -not $_.Completed 
    }
    
    if ($existingTask) {
        Write-Warning "Une tâche active avec cette description existe déjà (ID: $($existingTask.Id))"
        return $existingTask
    }

    # Crée une nouvelle tâche
    $task = [PSTask]::new()
    $task.Id = $script:NextTaskId++
    $task.Description = $Description
    
    # Gère la date d'échéance selon les paramètres
    if ($DueDate) {
        try {
            $task.DueDate = [datetime]$DueDate
        } catch {
            Write-Warning "Format de date invalide. Utilisez un format comme '2023-12-31' ou '31/12/2023'"
            return
        }
    } 
    elseif ($DueTomorrow) {
        $task.DueDate = (Get-Date).AddDays(1).Date
    }
    elseif ($DueNextWeek) {
        $task.DueDate = (Get-Date).AddDays(7).Date
    }
    elseif (-not $NoDefaultDueDate) {
        $task.DueDate = (Get-Date).Date
    }
    
    # Attribue les autres propriétés si présentes
    $task.Priority = $Priority
    if ($Tags) { $task.Tags = $Tags }
    if ($Notes) { $task.Notes = $Notes }

    # Ajoute la tâche à la liste et sauvegarde si confirmation
    if ($PSCmdlet.ShouldProcess($Description, "Ajout de tâche")) {
        $script:TaskList = @($script:TaskList) + @($task)
        Save-Tasks

        $dueInfo = if ($task.DueDate) { 
            " (échéance: $($task.DueDate.ToString('dd/MM/yyyy')))" 
        } else { 
            " (aucune échéance)" 
        }
        
        Write-Host "✅ Tâche #$($task.Id) ajoutée : " -NoNewline -ForegroundColor Green
        Write-Host $Description -NoNewline -ForegroundColor White
        Write-Host $dueInfo -ForegroundColor DarkGray
        return $task
    }
}

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

    # Détection d'une liste d'IDs (ex: "1,3,5")
    if ($IdOrDescription -match '^\d+(,\d+)*$') {
        $ids = $IdOrDescription -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
        $tasksToRemove = @()
        foreach ($idStr in $ids) {
            $id = [int]$idStr
            $task = $script:TaskList | Where-Object { $_.Id -eq $id }
            if (-not $task) {
                Write-Warning "Aucune tâche trouvée avec l'ID '$id'"
                continue
            }
            # Demande confirmation si la tâche n'est pas complétée et que -Force n'est pas utilisé
            if (-not $task.Completed -and -not $Force) {
                $confirmation = Read-Host "La tâche #$id n'est pas complétée. Supprimer quand même ? (O/N)"
                if ($confirmation -ne 'O') {
                    continue
                }
            }
            $tasksToRemove += $task
        }
        if ($tasksToRemove.Count -eq 0) { return }
        foreach ($task in $tasksToRemove) {
            if ($PSCmdlet.ShouldProcess($task.Description, "Suppression de tâche")) {
                $script:TaskList = $script:TaskList | Where-Object { $_.Id -ne $task.Id }
                Write-Host "🗑️ Tâche #$($task.Id) supprimée : $($task.Description)" -ForegroundColor Yellow
            }
        }
        Save-Tasks
        # Met à jour le prochain ID disponible
        $script:NextTaskId = ($script:TaskList | Measure-Object -Property Id -Maximum | Select-Object -ExpandProperty Maximum) + 1
        return $tasksToRemove
    }

    # Sinon, comportement classique (description ou ID unique)
    $isId = $false
    $id = 0
    if ([int]::TryParse($IdOrDescription, [ref]$id)) {
        $isId = $true
    }

    if ($isId) {
        # Suppression par ID unique
        $task = $script:TaskList | Where-Object { $_.Id -eq $id }
        if (-not $task) {
            Write-Warning "Aucune tâche trouvée avec l'ID '$id'"
            return
        }

        # Demande confirmation si la tâche n'est pas complétée et que -Force n'est pas utilisé
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
            $script:NextTaskId = ($script:TaskList | Measure-Object -Property Id -Maximum | Select-Object -ExpandProperty Maximum) + 1
            return $task
        }
    }
    else {
        # Suppression par description (ou description + CompletedOnly)
        $filter = { $_.Description -eq $IdOrDescription }
        if ($CompletedOnly) {
            $filter = { $_.Description -eq $IdOrDescription -and $_.Completed }
        }

        $matchingTasks = $script:TaskList | Where-Object $filter
        
        if (-not $matchingTasks) {
            Write-Warning "Aucune tâche trouvée avec cette description"
            return
        }

        # Si plusieurs tâches correspondent et que -Force n'est pas utilisé, demande confirmation
        if ($matchingTasks.Count -gt 1 -and -not $Force) {
            Write-Host "⚠️ Plusieurs tâches trouvées avec cette description :" -ForegroundColor Yellow
            $matchingTasks | Format-Table Id, Description, Priority, Completed -AutoSize
            Write-Host "Utilisez -Force pour toutes supprimer ou spécifiez l'ID"
            return
        }

        if ($PSCmdlet.ShouldProcess($IdOrDescription, "Suppression de tâche(s)")) {
            if ($Force) {
                # Supprime toutes les tâches correspondantes
                $script:TaskList = $script:TaskList | Where-Object { $_.Description -ne $IdOrDescription }
                $count = $matchingTasks.Count
            } else {
                # Supprime une seule tâche (priorité à celles non complétées)
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

function Get-Tasks {
    [CmdletBinding()]
    [Alias('gt')]
    [OutputType([PSTask])]
    param(
        [switch]$Completed,      # Affiche uniquement les tâches complétées
        [switch]$Pending,        # Affiche uniquement les tâches en attente
        [string]$Tag,            # Filtre par tag
        [TaskPriority]$Priority, # Filtre par priorité
        [int]$Limit,             # Limite le nombre de résultats
        [switch]$Overdue,        # Affiche uniquement les tâches en retard
        [switch]$DueToday,       # Affiche les tâches à faire aujourd'hui
        [switch]$DueThisWeek,    # Affiche les tâches à faire cette semaine
        [switch]$PassThru,       # Retourne les objets au lieu de les afficher
        [string]$Filter,         # Filtre texte sur description, tags ou notes
        [ValidateSet('Priority', 'DueDate', 'Created', 'Description')]
        [string]$SortBy = 'Priority', # Colonne de tri
        [switch]$Descending      # Tri descendant
    )

    $tasks = $script:TaskList

    # Applique les différents filtres selon les paramètres
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

    # Trie les tâches selon la colonne choisie
    $sortParams = @{
        Property = $SortBy
        Descending = $Descending
    }
    $tasks = $tasks | Sort-Object @sortParams

    # Limite le nombre de résultats si demandé
    if ($Limit -gt 0) { $tasks = $tasks | Select-Object -First $Limit }

    # Retourne les objets si PassThru, sinon affiche en table
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

    # Détermine si l'entrée est un ID numérique
    $isId = $false
    $id = 0
    if ([int]::TryParse($IdOrDescription, [ref]$id)) {
        $isId = $true
    }

    if ($isId) {
        # Recherche la tâche par ID
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
            # Arrête le chrono si en cours
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
        # Recherche par description (toutes les tâches non complétées)
        $tasks = $script:TaskList | Where-Object { 
            $_.Description -eq $IdOrDescription -and -not $_.Completed 
        }
        
        if (-not $tasks) {
            Write-Warning "Aucune tâche active trouvée avec cette description"
            return
        }

        # Si plusieurs tâches correspondent et que -All n'est pas utilisé, demande confirmation
        if ($tasks.Count -gt 1 -and -not $All) {
            Write-Host "⚠️ Plusieurs tâches trouvées avec cette description :" -ForegroundColor Yellow
            $tasks | Format-Table Id, Description, Priority, DueDate -AutoSize
            Write-Host "Utilisez -All pour toutes marquer comme complétées ou spécifiez l'ID"
            return
        }

        if ($PSCmdlet.ShouldProcess($IdOrDescription, "Marquer comme complétée(s)")) {
            $tasks | ForEach-Object { 
                # Arrête le chrono pour chaque tâche si nécessaire
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

function Update-Task {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName='ByIdOrDescription')]
    [Alias('ut')]
    param(
        [Parameter(Mandatory=$true, Position=0, ParameterSetName='ByIdOrDescription')]
        [string]$IdOrDescription,
        
        [string]$NewDescription,   # Nouvelle description éventuelle
        [datetime]$DueDate,        # Nouvelle date d'échéance
        [TaskPriority]$Priority,   # Nouvelle priorité
        [string[]]$Tags,           # Nouveaux tags
        [string]$Notes,            # Nouvelles notes
        [switch]$ClearDueDate,     # Effacer la date d'échéance
        [switch]$ClearTags,        # Effacer les tags
        [switch]$ClearNotes        # Effacer les notes
    )

    # Détermine si l'entrée est un ID numérique
    $isId = $false
    $id = 0
    if ([int]::TryParse($IdOrDescription, [ref]$id)) {
        $isId = $true
    }

    $task = $null
    if ($isId) {
        # Recherche la tâche par ID
        $task = $script:TaskList | Where-Object { $_.Id -eq $id }
        if (-not $task) {
            Write-Warning "Aucune tâche trouvée avec l'ID '$id'"
            return
        }
    }
    else {
        # Recherche la première tâche active correspondant à la description
        $task = $script:TaskList | Where-Object { 
            $_.Description -eq $IdOrDescription -and -not $_.Completed 
        } | Select-Object -First 1
        
        if (-not $task) {
            Write-Warning "Aucune tâche active trouvée avec la description '$IdOrDescription'"
            return
        }
    }

    # Vérifie qu'il n'y a pas de doublon de description si on la modifie
    if ($NewDescription -and $NewDescription -ne $task.Description) {
        $existingTask = $script:TaskList | Where-Object { 
            $_.Description -eq $NewDescription -and -not $_.Completed -and $_.Id -ne $task.Id
        }
        
        if ($existingTask) {
            Write-Warning "Une tâche active avec la description '$NewDescription' existe déjà (ID: $($existingTask.Id))"
            return
        }
    }

    # Applique les modifications si confirmation
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

## Fonctions utilitaires
function Get-TasksSummary {
    [CmdletBinding()]
    [Alias('gts')]
    param(
        [switch]$Detailed
    )

    # Calcule le total, le nombre de tâches complétées et en attente
    $total = $script:TaskList.Count
    $completed = ($script:TaskList | Where-Object { $_.Completed }).Count
    $pending = $total - $completed

    if ($total -eq 0) {
        # Affiche un message si aucune tâche n'existe
        Write-Host "Aucune tâche à l'horizon..." -ForegroundColor Yellow
        return
    }

    # Affiche les statistiques principales
    Write-Host "📊 Statistiques des tâches" -ForegroundColor Magenta
    Write-Host "Total: $total" -ForegroundColor White
    Write-Host "Complétées: $completed ($([math]::Round($completed/$total*100))%)" -ForegroundColor Green
    Write-Host "En attente: $pending ($([math]::Round($pending/$total*100))%)" -ForegroundColor Yellow

    # Si demandé, affiche la répartition par priorité
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

    # Affiche la liste des tâches urgentes si présentes
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
    # Affiche la liste des tâches en retard si présentes
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

    # Récupère toutes les tâches complétées
    $completed = $script:TaskList | Where-Object { $_.Completed }
    if (-not $completed) {
        Write-Host "Aucune tâche complétée à supprimer" -ForegroundColor Yellow
        return
    }

    # Archive les tâches complétées si demandé
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

    # Supprime les tâches complétées de la liste principale si confirmation
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

    # Calcule la date de fin pour le filtre
    $endDate = (Get-Date).AddDays($Days).Date

    # Sélectionne les tâches non complétées dont l'échéance est dans la période demandée
    $tasks = $script:TaskList | Where-Object { 
        -not $_.Completed -and 
        $_.DueDate -and 
        $_.DueDate -le $endDate -and 
        $_.DueDate -ge (Get-Date).Date
    } | Sort-Object DueDate

    if (-not $tasks) {
        # Affiche un message si aucune tâche n'est trouvée
        Write-Host "Aucune tâche à échéance dans les $Days jours" -ForegroundColor Yellow
        return
    }

    # Affiche la liste des tâches à échéance prochaine
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

    # Calcule la date cible pour le rappel
    $reminderDate = (Get-Date).AddDays($DaysAhead).Date

    # Sélectionne les tâches non complétées dont l'échéance correspond à la date cible
    $tasks = $script:TaskList | Where-Object { 
        -not $_.Completed -and 
        $_.DueDate -and 
        $_.DueDate.Date -eq $reminderDate 
    }

    if (-not $tasks) {
        # Affiche un message si aucune tâche n'est trouvée pour la date cible
        Write-Host "Aucune tâche à échéance demain" -ForegroundColor Yellow
        return
    }

    # Affiche la liste des tâches à rappeler
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
        # Recherche la tâche par ID (conversion en int)
        $taskId = 0
        if ([int]::TryParse($Id, [ref]$taskId)) {
            $task = $script:TaskList | Where-Object { $_.Id -eq $taskId }
        } else {
            Write-Warning "ID invalide : '$Id'. Veuillez utiliser un nombre entier."
            return
        }
    }
    else {
        # Recherche la première tâche active correspondant à la description
        $task = $script:TaskList | Where-Object { 
            $_.Description -eq $Description -and -not $_.Completed 
        } | Select-Object -First 1
    }
    
    if (-not $task) {
        # Affiche un message si aucune tâche n'est trouvée
        if ($PSCmdlet.ParameterSetName -eq 'ById') {
            Write-Warning "Aucune tâche trouvée avec l'ID '$Id'"
        } else {
            Write-Warning "Aucune tâche active trouvée avec la description '$Description'"
        }
        return
    }

    if ($task.IsTimerRunning()) {
        # Empêche de démarrer un chrono déjà en cours
        Write-Warning "Un chrono est déjà en cours pour cette tâche"
        return $task
    }

    if ($PSCmdlet.ShouldProcess($task.Description, "Démarrer le chrono")) {
        # Démarre le chrono, sauvegarde et affiche un message
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

    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        # Recherche la tâche par ID (conversion en int)
        $taskId = 0
        if ([int]::TryParse($Id, [ref]$taskId)) {
            $task = $script:TaskList | Where-Object { $_.Id -eq $taskId }
        } else {
            Write-Warning "ID invalide : '$Id'. Veuillez utiliser un nombre entier."
            return
        }
    }
    else {
        # Recherche la première tâche active correspondant à la description
        $task = $script:TaskList | Where-Object { 
            $_.Description -eq $Description -and -not $_.Completed 
        } | Select-Object -First 1
    }
    
    if (-not $task) {
        # Affiche un message si aucune tâche n'est trouvée
        if ($PSCmdlet.ParameterSetName -eq 'ById') {
            Write-Warning "Aucune tâche trouvée avec l'ID '$Id'"
        } else {
            Write-Warning "Aucune tâche active trouvée avec la description '$Description'"
        }
        return
    }

    if (-not $task.IsTimerRunning()) {
        # Empêche d'arrêter un chrono qui n'est pas en cours
        Write-Warning "Aucun chrono en cours pour cette tâche"
        return $task
    }

    if ($PSCmdlet.ShouldProcess($task.Description, "Arrêter le chrono")) {
        # Arrête le chrono, sauvegarde et affiche le temps écoulé
        $elapsed = $task.StopTimer()
        Save-Tasks
        
        Write-Host "⏱️ Chrono arrêté pour la tâche : " -NoNewline -ForegroundColor Cyan
        Write-Host $task.Description -ForegroundColor White -NoNewline
        Write-Host " (temps écoulé: $($elapsed.ToString('hh\:mm\:ss')))" -ForegroundColor DarkGray
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
        # Affiche le temps pour toutes les tâches ayant du temps enregistré
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

        # Calcule le temps total passé sur toutes les tâches
        $totalTime = [timespan]::Zero
        foreach($task in $tasksWithTime){ $totalTime += $task.TimeSpent }
        
        Write-Host "⏱️ Temps total enregistré : $($totalTime.ToString('hh\:mm\:ss'))" -ForegroundColor Green
        return
    }

    # Si recherche par ID
    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $task = $script:TaskList | Where-Object { $_.Id -eq [int]$Id }
        if (-not $task) {
            Write-Warning "Aucune tâche trouvée avec l'ID '$Id'"
            return
        }
    }
    else {
        # Si aucune description, affiche la tâche en cours (timer actif)
        if (-not $Description) {
            $task = $script:TaskList | Where-Object { $_.IsTimerRunning() } | Select-Object -First 1
            if (-not $task) {
                Write-Host "Aucune tâche en cours actuellement" -ForegroundColor Yellow
                return
            }
        }
        else {
            # Recherche par description
            $task = $script:TaskList | Where-Object { $_.Description -eq $Description } | Select-Object -First 1
            if (-not $task) {
                Write-Warning "Aucune tâche trouvée avec cette description"
                return
            }
        }
    }

    # Calcule et affiche le temps passé sur la tâche sélectionnée
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
