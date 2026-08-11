Set-StrictMode -Version Latest

function Get-FreshWinStatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [string]$StateDirectory
    )

    if (-not (Test-FreshWinSafeName -Name $Name)) {
        throw "State name '$Name' is invalid. Use letters, digits, dots, dashes, or underscores."
    }
    if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
        $StateDirectory = (Get-FreshWinPaths).State
    }

    return Join-Path ([System.IO.Path]::GetFullPath($StateDirectory)) "$Name.json"
}

function Save-FreshWinState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$State,

        [string]$StateDirectory
    )

    $path = Get-FreshWinStatePath -Name $Name -StateDirectory $StateDirectory
    $envelope = [PSCustomObject]@{
        schemaVersion = 1
        name          = $Name
        savedAt       = [System.DateTimeOffset]::UtcNow.ToString('o')
        data          = $State
    }
    [void](Write-FreshWinJsonFile -Path $path -Value $envelope -Depth 40 -Atomic)
    return $envelope
}

function Get-FreshWinState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [string]$StateDirectory,
        [switch]$AllowMissing,
        [switch]$Envelope,
        [switch]$DisableBackupRecovery
    )

    $path = Get-FreshWinStatePath -Name $Name -StateDirectory $StateDirectory
    if (-not [System.IO.File]::Exists($path)) {
        if ($AllowMissing) {
            return $null
        }
        throw "FreshWin state '$Name' was not found."
    }

    try {
        $saved = Read-FreshWinJsonFile -Path $path
    }
    catch {
        $backupPath = "$path.bak"
        if ($DisableBackupRecovery -or -not [System.IO.File]::Exists($backupPath)) {
            throw
        }
        $saved = Read-FreshWinJsonFile -Path $backupPath
    }

    $schemaVersion = [int](Get-FreshWinPropertyValue -InputObject $saved -Name 'schemaVersion' -Default 0)
    $savedName = [string](Get-FreshWinPropertyValue -InputObject $saved -Name 'name' -Default '')
    if ($schemaVersion -ne 1 -or $savedName -ne $Name -or
        -not (Test-FreshWinHasProperty -InputObject $saved -Name 'data')) {
        throw "FreshWin state '$Name' has an unsupported or invalid envelope."
    }

    if ($Envelope) {
        return $saved
    }
    return $saved.data
}

function Remove-FreshWinState {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [string]$StateDirectory
    )

    $path = Get-FreshWinStatePath -Name $Name -StateDirectory $StateDirectory
    if ([System.IO.File]::Exists($path) -and $PSCmdlet.ShouldProcess($path, 'Remove FreshWin state')) {
        [System.IO.File]::Delete($path)
    }
}

function New-FreshWinQueueItem {
    [CmdletBinding()]
    param(
        [string]$Id = ([guid]::NewGuid().ToString('N')),

        [Parameter(Mandatory = $true)]
        [ValidateSet('INSTALL', 'UPDATE', 'REPAIR', 'MANUAL', 'SYSTEM')]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetId,

        [string[]]$Prerequisites = @(),
        [bool]$RequiresAdmin = $false,

        [ValidateSet('SAFE', 'SYSTEM', 'ADVANCED')]
        [string]$SafetyLevel = 'SAFE',

        [ValidateRange(0, 10)]
        [int]$MaxRetries = 2,

        [ValidateSet('None', 'Possible', 'Required')]
        [string]$RestartImpact = 'None',

        [AllowNull()]
        [object]$Payload = $null
    )

    if (-not (Test-FreshWinSafeName -Name $Id)) {
        throw "Queue item ID '$Id' is invalid."
    }
    if ($TargetId -match '[\r\n\x00]') {
        throw 'Queue target IDs cannot contain control characters.'
    }

    return [PSCustomObject]@{
        id             = $Id
        type           = $Type
        targetId       = $TargetId
        prerequisites  = @($Prerequisites)
        requiresAdmin  = $RequiresAdmin
        safetyLevel    = $SafetyLevel
        state          = 'Pending'
        attempts       = 0
        maxRetries     = $MaxRetries
        result         = $null
        verification   = $null
        restartImpact  = $RestartImpact
        payload        = $Payload
        startedAt      = $null
        completedAt    = $null
    }
}

function ConvertTo-FreshWinQueueItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [ValidateRange(0, 10)]
        [int]$DefaultMaxRetries = 2
    )

    $type = [string](Get-FreshWinPropertyValue -InputObject $InputObject -Name 'type' -Default 'INSTALL')
    $targetId = [string](Get-FreshWinPropertyValue -InputObject $InputObject -Name 'targetId' -Default '')
    $id = [string](Get-FreshWinPropertyValue -InputObject $InputObject -Name 'id' -Default ([guid]::NewGuid().ToString('N')))
    $prerequisites = @(ConvertTo-FreshWinArray (Get-FreshWinPropertyValue -InputObject $InputObject -Name 'prerequisites' -Default @()))
    $requiresAdmin = [bool](Get-FreshWinPropertyValue -InputObject $InputObject -Name 'requiresAdmin' -Default $false)
    $safetyLevel = [string](Get-FreshWinPropertyValue -InputObject $InputObject -Name 'safetyLevel' -Default 'SAFE')
    $maxRetries = [int](Get-FreshWinPropertyValue -InputObject $InputObject -Name 'maxRetries' -Default $DefaultMaxRetries)
    $restartImpact = [string](Get-FreshWinPropertyValue -InputObject $InputObject -Name 'restartImpact' -Default 'None')
    $payload = Get-FreshWinPropertyValue -InputObject $InputObject -Name 'payload' -Default $null

    return New-FreshWinQueueItem `
        -Id $id `
        -Type $type `
        -TargetId $targetId `
        -Prerequisites @($prerequisites) `
        -RequiresAdmin $requiresAdmin `
        -SafetyLevel $safetyLevel `
        -MaxRetries $maxRetries `
        -RestartImpact $restartImpact `
        -Payload $payload
}

function New-FreshWinQueue {
    [CmdletBinding()]
    param(
        [string]$QueueId = ([guid]::NewGuid().ToString('N')),
        [string]$PlanId,
        [object[]]$Items = @(),
        [ValidateRange(0, 10)]
        [int]$DefaultMaxRetries = 2
    )

    if (-not (Test-FreshWinSafeName -Name $QueueId)) {
        throw "Queue ID '$QueueId' is invalid."
    }

    $normalizedItems = @()
    foreach ($item in $Items) {
        $normalizedItems += ,(ConvertTo-FreshWinQueueItem -InputObject $item -DefaultMaxRetries $DefaultMaxRetries)
    }
    $duplicateIds = @($normalizedItems | Group-Object id | Where-Object { $_.Count -gt 1 })
    if ($duplicateIds.Count -gt 0) {
        throw "Queue contains duplicate item ID '$($duplicateIds[0].Name)'."
    }

    $now = [System.DateTimeOffset]::UtcNow.ToString('o')
    return [PSCustomObject]@{
        schemaVersion    = 1
        queueId          = $QueueId
        planId           = $PlanId
        status           = 'Pending'
        createdAt        = $now
        updatedAt        = $now
        currentItemId    = $null
        rebootRequired   = $false
        resumeAfterReboot = $false
        resume           = $null
        items            = @($normalizedItems)
    }
}

function Add-FreshWinQueueItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Queue,

        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    $normalized = ConvertTo-FreshWinQueueItem -InputObject $Item
    if (@($Queue.items | Where-Object { $_.id -eq $normalized.id }).Count -gt 0) {
        throw "Queue item '$($normalized.id)' already exists."
    }
    $Queue.items = @($Queue.items) + @($normalized)
    $Queue.updatedAt = [System.DateTimeOffset]::UtcNow.ToString('o')
    return $Queue
}

function Set-FreshWinQueueItemState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Queue,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ItemId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Pending', 'Ready', 'Running', 'Succeeded', 'Failed', 'Skipped', 'Blocked', 'Manual', 'RebootPending', 'Cancelled', 'VerificationUnknown')]
        [string]$State,

        [AllowNull()]
        [object]$Result = $null,

        [AllowNull()]
        [object]$Verification = $null,

        [switch]$IncrementAttempt
    )

    $matches = @($Queue.items | Where-Object { $_.id -eq $ItemId })
    if ($matches.Count -ne 1) {
        throw "Queue item '$ItemId' was not found."
    }

    $item = $matches[0]
    if ($IncrementAttempt) {
        $item.attempts = [int]$item.attempts + 1
    }
    if ($State -eq 'Running' -and [string]::IsNullOrWhiteSpace([string]$item.startedAt)) {
        $item.startedAt = [System.DateTimeOffset]::UtcNow.ToString('o')
    }

    $terminalStates = @('Succeeded', 'Failed', 'Skipped', 'Blocked', 'Manual', 'Cancelled', 'VerificationUnknown')
    if ($terminalStates -contains $State) {
        $item.completedAt = [System.DateTimeOffset]::UtcNow.ToString('o')
    }
    $item.state = $State
    $item.result = $Result
    $item.verification = $Verification
    $Queue.currentItemId = if ($State -eq 'Running') { $ItemId } else { $null }
    $Queue.updatedAt = [System.DateTimeOffset]::UtcNow.ToString('o')

    $allItems = @($Queue.items)
    if (@($allItems | Where-Object { $_.state -eq 'RebootPending' }).Count -gt 0) {
        $Queue.status = 'AwaitingReboot'
        $Queue.rebootRequired = $true
    }
    elseif (@($allItems | Where-Object { $terminalStates -notcontains $_.state }).Count -eq 0) {
        if (@($allItems | Where-Object { $_.state -eq 'Failed' }).Count -gt 0) {
            $Queue.status = 'CompletedWithFailures'
        }
        elseif (@($allItems | Where-Object { $_.state -eq 'Cancelled' }).Count -gt 0) {
            $Queue.status = 'Cancelled'
        }
        else {
            $Queue.status = 'Completed'
        }
    }
    elseif ($State -eq 'Running') {
        $Queue.status = 'Running'
    }
    else {
        $Queue.status = 'Pending'
    }

    return $Queue
}

function Get-FreshWinNextQueueItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Queue
    )

    foreach ($item in @($Queue.items)) {
        if (@('Pending', 'Ready') -notcontains [string]$item.state) {
            continue
        }
        if ([int]$item.attempts -gt [int]$item.maxRetries) {
            continue
        }

        $requirementsMet = $true
        foreach ($prerequisiteId in @($item.prerequisites)) {
            $prerequisites = @($Queue.items | Where-Object { $_.id -eq $prerequisiteId })
            if ($prerequisites.Count -ne 1 -or
                @('Succeeded', 'Skipped') -notcontains [string]$prerequisites[0].state) {
                $requirementsMet = $false
                break
            }
        }
        if ($requirementsMet) {
            return $item
        }
    }
    return $null
}

function Test-FreshWinQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Queue
    )

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('schemaVersion', 'queueId', 'status', 'items')) {
        if (-not (Test-FreshWinHasProperty -InputObject $Queue -Name $name)) {
            $errors.Add("Missing queue property '$name'.")
        }
    }
    if ($errors.Count -eq 0) {
        if ([int]$Queue.schemaVersion -ne 1) {
            $errors.Add('Unsupported queue schema version.')
        }
        if (-not (Test-FreshWinSafeName -Name ([string]$Queue.queueId))) {
            $errors.Add('Invalid queue ID.')
        }
        $ids = @()
        foreach ($item in @($Queue.items)) {
            foreach ($propertyName in @('id', 'type', 'targetId', 'state', 'attempts', 'maxRetries')) {
                if (-not (Test-FreshWinHasProperty -InputObject $item -Name $propertyName)) {
                    $errors.Add("Queue item is missing '$propertyName'.")
                }
            }
            if (Test-FreshWinHasProperty -InputObject $item -Name 'id') {
                $ids += [string]$item.id
            }
        }
        foreach ($duplicate in @($ids | Group-Object | Where-Object { $_.Count -gt 1 })) {
            $errors.Add("Duplicate queue item ID '$($duplicate.Name)'.")
        }
    }

    return [PSCustomObject]@{
        IsValid = $errors.Count -eq 0
        Errors  = $errors.ToArray()
    }
}

function Save-FreshWinQueueCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Queue,
        [string]$StateDirectory
    )

    $validation = Test-FreshWinQueue -Queue $Queue
    if (-not $validation.IsValid) {
        throw "Queue cannot be saved: $($validation.Errors -join ' ')"
    }
    $Queue.updatedAt = [System.DateTimeOffset]::UtcNow.ToString('o')
    [void](Save-FreshWinState -Name 'active-queue' -State $Queue -StateDirectory $StateDirectory)
    return $Queue
}

function Get-FreshWinQueueCheckpoint {
    [CmdletBinding()]
    param(
        [string]$StateDirectory,
        [switch]$AllowMissing
    )

    $queue = Get-FreshWinState -Name 'active-queue' -StateDirectory $StateDirectory -AllowMissing:$AllowMissing
    if ($null -eq $queue) {
        return $null
    }
    $validation = Test-FreshWinQueue -Queue $queue
    if (-not $validation.IsValid) {
        throw "Saved queue is invalid: $($validation.Errors -join ' ')"
    }
    return $queue
}

function Set-FreshWinQueueRebootCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Queue,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason,
        [string]$NextItemId,
        [string]$StateDirectory
    )

    $Queue.status = 'AwaitingReboot'
    $Queue.rebootRequired = $true
    $Queue.resumeAfterReboot = $true
    $Queue.resume = [PSCustomObject]@{
        requestedAt = [System.DateTimeOffset]::UtcNow.ToString('o')
        reason      = $Reason
        nextItemId  = $NextItemId
    }
    return Save-FreshWinQueueCheckpoint -Queue $Queue -StateDirectory $StateDirectory
}

function Remove-FreshWinQueueCheckpoint {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [string]$StateDirectory
    )

    if ($PSCmdlet.ShouldProcess('active-queue', 'Remove FreshWin queue checkpoint')) {
        Remove-FreshWinState -Name 'active-queue' -StateDirectory $StateDirectory -Confirm:$false
    }
}
