################################################################################################################
# CONFIGURATION
################################################################################################################

# Azure
$SubscriptionId     = "00000000-0000-0000-0000-000000000000"
$ResourceGroupName  = "rg-storage-prod"
$StorageAccountName = "stfilesprod01"

# Share handling
$UseMultipleShares  = $true
$SingleShareName    = "fslogix"
$ShareNames         = @(
    "fslogix-a",
    "fslogix-b",
    "fslogix-c"
)

# Share model: PremiumV1 or ProvisionedV2
$ShareModel = "PremiumV1"

# Thresholds
$GrowThresholdPercent   = 85
$ShrinkThresholdPercent = 70
$ShrinkTargetPercent    = 80
$GrowByPercent          = 20

# Safety / behaviour
$ShrinkLockDays = 30
$MaxGrowthGiB   = 100
$WhatIfMode     = $false

# State variable names (must already exist in Automation as NON-ENCRYPTED variables)
$LastGrowTimesVariableName = "FSLogix-LastGrowTimesJson"
$ShrinkCountsVariableName  = "FSLogix-ShrinkCountsJson"

# Consecutive shrink tracking
$ConsecutiveShrinkAlertThreshold = 3

################################################################################################################
# MODULES
################################################################################################################
Import-Module Az.Accounts
Import-Module Az.Storage

################################################################################################################
# LOGGING
################################################################################################################
function Write-Log {
    param(
        [string]$Message,
        [string]$ShareName = ""
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    if ([string]::IsNullOrWhiteSpace($ShareName)) {
        Write-Output "[$timestamp] $Message"
    }
    else {
        Write-Output "[$timestamp] [$ShareName] $Message"
    }
}

function Fail-Step {
    param(
        [string]$Step,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$ShareName = ""
    )

    Write-Log "================ ERROR BEGIN ================" $ShareName
    Write-Log "FAILED at [$Step]" $ShareName

    if ($null -ne $ErrorRecord) {
        if ($ErrorRecord.Exception) {
            Write-Log ("Message: " + $ErrorRecord.Exception.Message) $ShareName

            if ($ErrorRecord.Exception.InnerException) {
                Write-Log ("InnerException: " + $ErrorRecord.Exception.InnerException.Message) $ShareName
            }
        }

        if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.Line) {
            Write-Log ("Invocation line: " + $ErrorRecord.InvocationInfo.Line) $ShareName
        }

        Write-Log (($ErrorRecord | Format-List * -Force | Out-String)) $ShareName
    }

    Write-Log "================ ERROR END ==================" $ShareName
    throw $ErrorRecord
}

################################################################################################################
# HELPERS
################################################################################################################
function Get-ShareLimits {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Model
    )

    switch ($Model) {
        "PremiumV1" {
            return @{
                MinQuotaGiB = 100
                MaxQuotaGiB = 102400
            }
        }
        "ProvisionedV2" {
            return @{
                MinQuotaGiB = 32
                MaxQuotaGiB = 262144
            }
        }
        default {
            throw "Unsupported ShareModel '$Model'."
        }
    }
}

function Clamp-Quota {
    param(
        [Parameter(Mandatory = $true)]
        [int]$RequestedQuotaGiB,
        [Parameter(Mandatory = $true)]
        [int]$UsedGiBRoundedUp,
        [Parameter(Mandatory = $true)]
        [int]$MinQuotaGiB,
        [Parameter(Mandatory = $true)]
        [int]$MaxQuotaGiB
    )

    $result = $RequestedQuotaGiB

    if ($result -lt $UsedGiBRoundedUp) { $result = $UsedGiBRoundedUp }
    if ($result -lt $MinQuotaGiB)      { $result = $MinQuotaGiB }
    if ($result -gt $MaxQuotaGiB)      { $result = $MaxQuotaGiB }

    return [int]$result
}

function Get-ShareList {
    if ($UseMultipleShares) {
        $shares = $ShareNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }

        if (-not $shares -or $shares.Count -eq 0) {
            throw "UseMultipleShares is enabled but ShareNames is empty."
        }

        return $shares
    }

    if ([string]::IsNullOrWhiteSpace($SingleShareName)) {
        throw "UseMultipleShares is disabled but SingleShareName is empty."
    }

    return @($SingleShareName.Trim())
}

function Get-StateHashtableFromAutomationVariable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VariableName
    )

    $raw = Get-AutomationVariable -Name $VariableName -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $hash = @{}

        if ($obj -is [System.Collections.IDictionary]) {
            foreach ($key in $obj.Keys) {
                $hash[$key] = $obj[$key]
            }
        }
        else {
            foreach ($p in $obj.PSObject.Properties) {
                $hash[$p.Name] = $p.Value
            }
        }

        return $hash
    }
    catch {
        Write-Log "State variable '$VariableName' contains invalid JSON. Resetting to empty state."
        return @{}
    }
}

function Save-StateHashtableToAutomationVariable {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,
        [Parameter(Mandatory = $true)]
        [string]$VariableName
    )

    $json = $State | ConvertTo-Json -Depth 10 -Compress
    Set-AutomationVariable -Name $VariableName -Value $json
}

function Get-LastGrowTimeUtcForShare {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,
        [Parameter(Mandatory = $true)]
        [string]$ShareName
    )

    if (-not $State.ContainsKey($ShareName)) {
        return $null
    }

    $rawValue = [string]$State[$ShareName]

    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return $null
    }

    try {
        return [DateTime]::Parse($rawValue).ToUniversalTime()
    }
    catch {
        Write-Log "Stored last grow time is invalid: '$rawValue'. Ignoring." $ShareName
        return $null
    }
}

function Set-LastGrowTimeUtcForShare {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,
        [Parameter(Mandatory = $true)]
        [string]$ShareName,
        [Parameter(Mandatory = $true)]
        [datetime]$TimestampUtc
    )

    $State[$ShareName] = $TimestampUtc.ToString("o")
}

function Get-ConsecutiveShrinkCountForShare {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,
        [Parameter(Mandatory = $true)]
        [string]$ShareName
    )

    if ($State.ContainsKey($ShareName)) {
        return [int]$State[$ShareName]
    }

    return 0
}

function Set-ConsecutiveShrinkCountForShare {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,
        [Parameter(Mandatory = $true)]
        [string]$ShareName,
        [Parameter(Mandatory = $true)]
        [int]$Count
    )

    $State[$ShareName] = $Count
}

################################################################################################################
# AUTH
################################################################################################################
$ErrorActionPreference = "Stop"

try {
    Write-Log "Runbook starting"
    Write-Log "Authenticating with managed identity..."
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Log "Authenticated successfully"
}
catch {
    Fail-Step "AUTH" $_
}

################################################################################################################
# INITIALISE
################################################################################################################
try {
    $ShareLimits = Get-ShareLimits -Model $ShareModel
    $SharesToProcess = Get-ShareList
    $LastGrowTimesState = Get-StateHashtableFromAutomationVariable -VariableName $LastGrowTimesVariableName
    $ShrinkCountsState  = Get-StateHashtableFromAutomationVariable -VariableName $ShrinkCountsVariableName

    Write-Log "Storage account: $StorageAccountName"
    Write-Log "Resource group: $ResourceGroupName"
    Write-Log "Share model: $ShareModel"
    Write-Log "Use multiple shares: $UseMultipleShares"
    Write-Log "Shrink lock days: $ShrinkLockDays"
    Write-Log "Max growth per run: $MaxGrowthGiB GiB"
    Write-Log "WhatIf mode: $WhatIfMode"
    Write-Log ("Shares to process: " + ($SharesToProcess -join ", "))
}
catch {
    Fail-Step "INITIALISE" $_
}

################################################################################################################
# PROCESS EACH SHARE
################################################################################################################
foreach ($ShareName in $SharesToProcess) {
    try {
        Write-Log "--------------------------------------------------------------------------------" $ShareName
        Write-Log "Run started for share" $ShareName

        $share = Get-AzRmStorageShare `
            -ResourceGroupName $ResourceGroupName `
            -StorageAccountName $StorageAccountName `
            -Name $ShareName `
            -GetShareUsage `
            -ErrorAction Stop

        if (-not $share) {
            throw "Share '$ShareName' not found."
        }

        $currentQuotaGiB = [int]$share.QuotaGiB
        $oldQuotaGiB     = $currentQuotaGiB
        $newQuotaGiB     = $currentQuotaGiB

        $usedBytes        = [double]$share.ShareUsageBytes
        $usedGiBExact     = $usedBytes / 1GB
        $usedGiBRoundedUp = [int][math]::Ceiling($usedGiBExact)

        if ($currentQuotaGiB -le 0) {
            throw "Current quota is invalid: $currentQuotaGiB GiB"
        }

        $utilizationPercent = [math]::Round(($usedGiBExact / $currentQuotaGiB) * 100, 2)

        Write-Log "Current quota: $currentQuotaGiB GiB" $ShareName
        Write-Log ("Current usage: {0:N2} GiB" -f $usedGiBExact) $ShareName
        Write-Log "Current utilization: $utilizationPercent%" $ShareName

        ########################################################################################################
        # SHRINK LOCK STATE
        ########################################################################################################
        $nowUtc = (Get-Date).ToUniversalTime()
        $lastGrowTimeUtc = Get-LastGrowTimeUtcForShare -State $LastGrowTimesState -ShareName $ShareName
        $shrinkLockedUntilUtc = $null
        $shrinkLocked = $false
        $lockDaysRemaining = 0

        if ($lastGrowTimeUtc) {
            $shrinkLockedUntilUtc = $lastGrowTimeUtc.AddDays($ShrinkLockDays)

            if ($nowUtc -lt $shrinkLockedUntilUtc) {
                $shrinkLocked = $true
                $remainingTime = $shrinkLockedUntilUtc - $nowUtc
                $lockDaysRemaining = [math]::Ceiling($remainingTime.TotalDays)

                Write-Log ("Last growth: {0}" -f $lastGrowTimeUtc.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")) $ShareName
                Write-Log ("Shrink lock active until: {0}" -f $shrinkLockedUntilUtc.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")) $ShareName
                Write-Log ("Days remaining before shrinking is allowed again: {0}" -f $lockDaysRemaining) $ShareName
            }
            else {
                Write-Log ("Last growth: {0}" -f $lastGrowTimeUtc.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")) $ShareName
                Write-Log "Shrink lock has expired. Shrinking is allowed if thresholds are met." $ShareName
                Write-Log "Days remaining before shrinking is allowed again: 0" $ShareName
            }
        }
        else {
            Write-Log "No previous growth timestamp found for this share." $ShareName
            Write-Log "Days remaining before shrinking is allowed again: 0" $ShareName
        }

        ########################################################################################################
        # DECISION
        ########################################################################################################
        $action = "None"
        $requestedQuotaGiB = $currentQuotaGiB
        $reason = "Utilization is between thresholds; no change required."

        if ($utilizationPercent -gt $GrowThresholdPercent) {
            $action = "Grow"

            $percentGrowthTarget = [int][math]::Ceiling($currentQuotaGiB * (1 + ($GrowByPercent / 100)))
            $maxAllowedGrowthTarget = $currentQuotaGiB + $MaxGrowthGiB

            $requestedQuotaGiB = [math]::Min($percentGrowthTarget, $maxAllowedGrowthTarget)
            $reason = "Utilization is above $GrowThresholdPercent%; growing by $GrowByPercent% (capped at +$MaxGrowthGiB GiB per run)."
        }
        elseif ($utilizationPercent -le $ShrinkThresholdPercent) {
            if ($shrinkLocked) {
                $action = "None"
                $requestedQuotaGiB = $currentQuotaGiB
                $reason = "Utilization is low enough to shrink, but shrink lock is still active."
            }
            else {
                $action = "Shrink"
                $requestedQuotaGiB = [int][math]::Ceiling($usedGiBExact / ($ShrinkTargetPercent / 100))
                $reason = "Utilization is at or below $ShrinkThresholdPercent%; reducing quota to target ~$ShrinkTargetPercent% utilization."
            }
        }

        $targetQuotaGiB = Clamp-Quota `
            -RequestedQuotaGiB $requestedQuotaGiB `
            -UsedGiBRoundedUp $usedGiBRoundedUp `
            -MinQuotaGiB $ShareLimits.MinQuotaGiB `
            -MaxQuotaGiB $ShareLimits.MaxQuotaGiB

        $newQuotaGiB = $targetQuotaGiB
        $projectedUtilization = [math]::Round(($usedGiBExact / $newQuotaGiB) * 100, 2)

        Write-Log "Decision: $action" $ShareName
        Write-Log $reason $ShareName
        Write-Log "Requested target quota: $requestedQuotaGiB GiB" $ShareName
        Write-Log "Clamped target quota: $targetQuotaGiB GiB" $ShareName
        Write-Log "Projected utilization after change: $projectedUtilization%" $ShareName

        ########################################################################################################
        # APPLY
        ########################################################################################################
        $resizeApplied = $false

        if ($action -eq "None") {
            Write-Log "No resize required." $ShareName
        }
        elseif ($newQuotaGiB -eq $currentQuotaGiB) {
            Write-Log "Calculated target equals current quota; no update required." $ShareName
        }
        elseif ($WhatIfMode) {
            Write-Log "WhatIfMode enabled. No change applied." $ShareName
            Write-Log "Would set quota from $currentQuotaGiB GiB to $newQuotaGiB GiB." $ShareName

            if ($action -eq "Grow") {
                $whatIfGrowTimeUtc = $nowUtc
                $whatIfShrinkUnlockUtc = $whatIfGrowTimeUtc.AddDays($ShrinkLockDays)
                Write-Log ("Would refresh shrink lock until: {0}" -f $whatIfShrinkUnlockUtc.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")) $ShareName
            }
        }
        else {
            Write-Log "Updating share quota from $currentQuotaGiB GiB to $newQuotaGiB GiB..." $ShareName
            Update-AzRmStorageShare `
                -ResourceGroupName $ResourceGroupName `
                -StorageAccountName $StorageAccountName `
                -Name $ShareName `
                -QuotaGiB $newQuotaGiB `
                -ErrorAction Stop | Out-Null

            Write-Log "Quota updated successfully." $ShareName
            $resizeApplied = $true

            if ($action -eq "Grow") {
                $newGrowTimeUtc = (Get-Date).ToUniversalTime()
                Set-LastGrowTimeUtcForShare -State $LastGrowTimesState -ShareName $ShareName -TimestampUtc $newGrowTimeUtc

                $newShrinkUnlockUtc = $newGrowTimeUtc.AddDays($ShrinkLockDays)
                $lockDaysRemaining = [math]::Ceiling(($newShrinkUnlockUtc - $newGrowTimeUtc).TotalDays)

                Write-Log ("Recorded last growth time: {0}" -f $newGrowTimeUtc.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")) $ShareName
                Write-Log ("Shrink locked until: {0}" -f $newShrinkUnlockUtc.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")) $ShareName
                Write-Log ("Days remaining before shrinking is allowed again: {0}" -f $lockDaysRemaining) $ShareName
            }
        }

        ########################################################################################################
        # CONSECUTIVE SHRINK TRACKING
        ########################################################################################################
        $previousShrinkCount = Get-ConsecutiveShrinkCountForShare -State $ShrinkCountsState -ShareName $ShareName
        $currentShrinkCount = $previousShrinkCount

        if (($action -eq "Shrink") -and ($newQuotaGiB -lt $oldQuotaGiB) -and (($resizeApplied -eq $true) -or $WhatIfMode)) {
            $currentShrinkCount = $previousShrinkCount + 1
            Set-ConsecutiveShrinkCountForShare -State $ShrinkCountsState -ShareName $ShareName -Count $currentShrinkCount
            Write-Log "Consecutive shrink count increased from $previousShrinkCount to $currentShrinkCount." $ShareName
        }
        else {
            if ($previousShrinkCount -ne 0) {
                Write-Log "Consecutive shrink count reset from $previousShrinkCount to 0." $ShareName
            }

            $currentShrinkCount = 0
            Set-ConsecutiveShrinkCountForShare -State $ShrinkCountsState -ShareName $ShareName -Count 0
        }

        ########################################################################################################
        # SUMMARY
        ########################################################################################################
        $summary = "SUMMARY | Share=$ShareName | Action=$action | OldQuota=$oldQuotaGiB | NewQuota=$newQuotaGiB | UsedGiB=$([math]::Round($usedGiBExact,2)) | Util=$utilizationPercent | LockDaysRemaining=$lockDaysRemaining | ConsecutiveShrinks=$currentShrinkCount"
        Write-Output $summary

        if ($currentShrinkCount -ge $ConsecutiveShrinkAlertThreshold) {
            Write-Log "Consecutive shrink threshold reached for this share: $currentShrinkCount" $ShareName
        }

        Write-Log "Run finished for share" $ShareName
    }
    catch {
        Fail-Step "PROCESS SHARE" $_ $ShareName
    }
}

################################################################################################################
# SAVE STATE
################################################################################################################
try {
    Save-StateHashtableToAutomationVariable -State $LastGrowTimesState -VariableName $LastGrowTimesVariableName
    Write-Log "Saved per-share growth state to Automation Variable '$LastGrowTimesVariableName'."

    Save-StateHashtableToAutomationVariable -State $ShrinkCountsState -VariableName $ShrinkCountsVariableName
    Write-Log "Saved per-share shrink count state to Automation Variable '$ShrinkCountsVariableName'."
}
catch {
    Fail-Step "SAVE STATE" $_
}

Write-Log "Runbook complete"
