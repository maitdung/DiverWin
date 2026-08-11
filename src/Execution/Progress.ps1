Set-StrictMode -Version 2.0

function Get-FreshWinExecutionStageDefinitions {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{ Number=1; Id='CHECKING_INSTALLED_STATE'; Label='Checking installed state' }
        [pscustomobject]@{ Number=2; Id='RESOLVING_SOURCE'; Label='Resolving trusted source' }
        [pscustomobject]@{ Number=3; Id='DOWNLOADING'; Label='Downloading' }
        [pscustomobject]@{ Number=4; Id='INSTALLING'; Label='Installing' }
        [pscustomobject]@{ Number=5; Id='VERIFYING'; Label='Verifying' }
        [pscustomobject]@{ Number=6; Id='REFRESHING_INVENTORY'; Label='Refreshing inventory' }
    )
}

function New-FreshWinProgressEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][ValidateSet(
            'CHECKING_INSTALLED_STATE', 'RESOLVING_SOURCE', 'DOWNLOADING',
            'INSTALLING', 'VERIFYING', 'REFRESHING_INVENTORY', 'COMPLETE'
        )][string]$Stage,
        [ValidateSet('Waiting', 'InProgress', 'Succeeded', 'Skipped', 'Failed', 'Manual', 'Unknown', 'Complete')]
        [string]$Status = 'InProgress',
        [string]$Detail,
        [int]$Position,
        [int]$Total,
        [AllowNull()][object]$Source = $null,
        [AllowNull()][object]$ExitCode = $null,
        [AllowNull()][object]$BackendPercent = $null,
        [AllowNull()][object]$ElapsedSeconds = $null
    )

    $definition = @(Get-FreshWinExecutionStageDefinitions | Where-Object Id -eq $Stage | Select-Object -First 1)
    $stageNumber = if ($definition.Count -eq 1) { [int]$definition[0].Number } else { 0 }
    $stageLabel = if ($definition.Count -eq 1) { [string]$definition[0].Label } else { 'Complete' }
    $event = [pscustomobject][ordered]@{
        TimestampUtc = [DateTimeOffset]::UtcNow
        PackageId    = [string]$Item.PackageId
        Name         = [string](Get-FreshWinPropertyValue -InputObject $Item.Package -Name 'name' -Default $Item.PackageId)
        Stage        = $Stage
        StageNumber  = $stageNumber
        StageTotal   = 6
        StageLabel   = $stageLabel
        Status       = $Status
        Detail       = [string]$Detail
        Position     = $Position
        Total        = $Total
        Source       = $Source
        ExitCode     = $ExitCode
        ElapsedSeconds = $ElapsedSeconds
        ItemState    = [string]$Item.State
    }

    # Queue position is not download/install progress. A percentage exists
    # only when the active backend explicitly supplied a trustworthy value.
    $parsedPercent = 0.0
    if ($null -ne $BackendPercent -and [double]::TryParse([string]$BackendPercent, [ref]$parsedPercent) -and
        $parsedPercent -ge 0 -and $parsedPercent -le 100) {
        $event | Add-Member -NotePropertyName Percent -NotePropertyValue $parsedPercent
    }
    return $event
}

function Get-FreshWinExecutionSourceLabel {
    [CmdletBinding()]
    param([AllowNull()][object]$ResolvedSource)

    if ($null -eq $ResolvedSource) { return '' }
    $sourceName = [string](Get-FreshWinPropertyValue -InputObject $ResolvedSource -Name 'SourceName' -Default (
        Get-FreshWinPropertyValue -InputObject $ResolvedSource -Name 'SourceType' -Default ''))
    $packageManagerId = [string](Get-FreshWinPropertyValue -InputObject $ResolvedSource -Name 'PackageManagerId' -Default '')
    if ($sourceName -and $packageManagerId) { return "$sourceName / $packageManagerId" }
    if ($sourceName) { return $sourceName }
    return $packageManagerId
}

function Get-FreshWinProcessOutputSummary {
    [CmdletBinding()]
    param([AllowNull()][object]$ProcessResult, [ValidateRange(80, 2000)][int]$MaximumLength = 500)

    if ($null -eq $ProcessResult) { return '' }
    $results = @($ProcessResult)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($result in $results) {
        foreach ($name in @('StandardError', 'StdErr', 'StandardOutput', 'StdOut', 'Error')) {
            $value = [string](Get-FreshWinPropertyValue -InputObject $result -Name $name -Default '')
            foreach ($line in @($value -split '\r?\n')) {
                $safeLine = if (Get-Command -Name Protect-FreshWinSensitiveText -ErrorAction SilentlyContinue) {
                    Protect-FreshWinSensitiveText -Text ([string]$line)
                } else { [string]$line }
                $safeLine = $safeLine.Trim()
                if ($safeLine) { $lines.Add($safeLine) }
            }
        }
    }
    if ($lines.Count -eq 0) { return '' }
    $summary = @($lines | Select-Object -Unique | Select-Object -First 4) -join ' | '
    if ($summary.Length -le $MaximumLength) { return $summary }
    return $summary.Substring(0, [Math]::Max(0, $MaximumLength - 3)) + '...'
}

function ConvertTo-FreshWinExecutionItemReport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Item, [switch]$IncludeDetails)

    $result = Get-FreshWinPropertyValue -InputObject $Item -Name 'Result' -Default $null
    $verification = Get-FreshWinPropertyValue -InputObject $Item -Name 'Verification' -Default $null
    $state = [string](Get-FreshWinPropertyValue -InputObject $Item -Name 'State' -Default 'PENDING')
    $action = [string](Get-FreshWinPropertyValue -InputObject $Item -Name 'Action' -Default '')
    $outcome = switch ($state) {
        'SUCCEEDED' { if ($action -eq 'UPDATE') { 'Updated' } else { 'Installed' } }
        'SKIP' { 'Skipped' }
        'MANUAL' { 'Manual' }
        'UNKNOWN_VERIFICATION' { 'Unknown verification' }
        'VALIDATED' { 'Validated' }
        { $_ -in @('FAILED', 'BLOCKED', 'ELEVATION_REQUIRED') } { 'Failed' }
        default { 'Pending' }
    }
    $reason = [string](Get-FreshWinPropertyValue -InputObject $verification -Name 'Detail' -Default '')
    if (-not $reason) { $reason = [string](Get-FreshWinPropertyValue -InputObject $result -Name 'Message' -Default '') }
    if (-not $reason) { $reason = [string](Get-FreshWinPropertyValue -InputObject $Item -Name 'Reason' -Default '') }
    $processResult = Get-FreshWinPropertyValue -InputObject $result -Name 'ProcessResult' -Default $null
    $report = [pscustomobject][ordered]@{
        PackageId    = [string]$Item.PackageId
        Name         = [string](Get-FreshWinPropertyValue -InputObject $Item.Package -Name 'name' -Default $Item.PackageId)
        Action       = $action
        Outcome      = $outcome
        State        = $state
        FailedStage  = if ($outcome -in @('Failed', 'Unknown verification', 'Manual')) {
            [string](Get-FreshWinPropertyValue -InputObject $result -Name 'Stage' -Default $(if ($state -eq 'UNKNOWN_VERIFICATION') { 'Verify' } else { '' }))
        } else { '' }
        Source       = Get-FreshWinExecutionSourceLabel -ResolvedSource (Get-FreshWinPropertyValue -InputObject $Item -Name 'ResolvedSource' -Default $null)
        ExitCode     = Get-FreshWinPropertyValue -InputObject $result -Name 'ExitCode' -Default $null
        Reason       = $reason
        Verified     = [bool](Get-FreshWinPropertyValue -InputObject $verification -Name 'Verified' -Default $false)
        Verification = [string](Get-FreshWinPropertyValue -InputObject $verification -Name 'Status' -Default 'NotRun')
        OutputSummary = Get-FreshWinProcessOutputSummary -ProcessResult $processResult
    }
    if ($IncludeDetails) {
        $report | Add-Member -NotePropertyName Details -NotePropertyValue $processResult
    }
    return $report
}

function New-FreshWinExecutionReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$ExecutionResult,
        [AllowNull()][object[]]$Progress = @(),
        [switch]$IncludeDetails
    )

    $plan = Get-FreshWinPropertyValue -InputObject $ExecutionResult -Name 'Plan' -Default $null
    return [pscustomobject][ordered]@{
        Status   = [string](Get-FreshWinPropertyValue -InputObject $ExecutionResult -Name 'Status' -Default 'Unknown')
        PlanId   = [string](Get-FreshWinPropertyValue -InputObject $plan -Name 'Id' -Default '')
        Progress = @($Progress)
        Items    = @((Get-FreshWinPropertyValue -InputObject $plan -Name 'Items' -Default @()) | ForEach-Object {
            ConvertTo-FreshWinExecutionItemReport -Item $_ -IncludeDetails:$IncludeDetails
        })
        Summary  = Get-FreshWinPropertyValue -InputObject $ExecutionResult -Name 'Summary' -Default $null
    }
}

function New-FreshWinElevatedFailureExecutionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [AllowNull()][object]$ChildResult,
        [AllowNull()][object]$ChildExitCode = $null,
        [AllowNull()][object[]]$Progress = @(),
        [string]$FallbackReason = 'The administrator-authorized execution helper did not complete successfully.'
    )

    $childStage = [string](Get-FreshWinPropertyValue -InputObject $ChildResult -Name 'stage' -Default 'ElevationHandoff')
    if ([string]::IsNullOrWhiteSpace($childStage)) { $childStage = 'ElevationHandoff' }
    $childReason = [string](Get-FreshWinPropertyValue -InputObject $ChildResult -Name 'reason' -Default '')
    $exceptionMessage = [string](Get-FreshWinPropertyValue -InputObject $ChildResult -Name 'exceptionMessage' -Default '')
    $exceptionType = [string](Get-FreshWinPropertyValue -InputObject $ChildResult -Name 'exceptionType' -Default '')
    if ([string]::IsNullOrWhiteSpace($childReason)) { $childReason = $exceptionMessage }
    if ([string]::IsNullOrWhiteSpace($childReason)) { $childReason = $FallbackReason }
    $reportedExitCode = Get-FreshWinPropertyValue -InputObject $ChildResult -Name 'childExitCode' -Default $ChildExitCode
    $childItems = @(Get-FreshWinPropertyValue -InputObject $ChildResult -Name 'items' -Default @())

    foreach ($item in @($Plan.Items | Where-Object { $_.Action -in @('INSTALL', 'UPDATE', 'REPAIR') -and $_.State -notin @('SUCCEEDED', 'SKIP') })) {
        $reportedItem = @($childItems | Where-Object { [string](Get-FreshWinPropertyValue $_ 'packageId' '') -eq [string]$item.PackageId } | Select-Object -First 1)
        $itemStage = $childStage
        $itemReason = $childReason
        $itemExitCode = $reportedExitCode
        if ($reportedItem.Count -eq 1) {
            $reportedStage = [string](Get-FreshWinPropertyValue $reportedItem[0] 'stage' '')
            $reportedReason = [string](Get-FreshWinPropertyValue $reportedItem[0] 'reason' '')
            if ($reportedStage) { $itemStage = $reportedStage }
            if ($reportedReason) { $itemReason = $reportedReason }
            $itemExitCode = Get-FreshWinPropertyValue $reportedItem[0] 'exitCode' $reportedExitCode
            $item.Verification = [pscustomobject]@{
                Status = [string](Get-FreshWinPropertyValue $reportedItem[0] 'verification' 'NotRun')
                Verified = [bool](Get-FreshWinPropertyValue $reportedItem[0] 'verified' $false)
                Detail = $itemReason
            }
        }
        $item.State = 'FAILED'
        $item.Result = [pscustomobject]@{
            Outcome='Failed'; Stage=$itemStage; Attempts=[int](Get-FreshWinPropertyValue $item 'Attempts' 0)
            ExitCode=$itemExitCode; Message=$itemReason; ProcessResult=$null
            ExceptionType=$exceptionType; ExceptionMessage=$exceptionMessage
        }
    }
    $Plan.Status = 'COMPLETED_WITH_ISSUES'
    return [pscustomobject]@{
        Status='COMPLETED_WITH_ISSUES'
        Plan=$Plan
        Summary=(Get-FreshWinExecutionSummary -Plan $Plan)
        Progress=@($Progress)
        ChildResult=$ChildResult
    }
}
