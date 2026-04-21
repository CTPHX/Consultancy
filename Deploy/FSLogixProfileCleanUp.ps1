################################################################################################################
# README
# © Phoenix Software 2026
# Developed in the style of FileShareGrowAndShrink.ps1
#
# PURPOSE
# - Connect to Azure using the Automation Account managed identity
# - Traverse one or more Azure File Shares recursively
# - Identify avhdx files whose LastModified date is older than the configured retention period
# - Delete matching files, or log only when WhatIfMode is enabled
#
# REQUIRED RBAC
# - Management plane access to the storage account resource
# - Data plane access to Azure Files sufficient to list and delete files
# - Storage File Data SMB Share Contributor & Storage Account Contributor at the Storage Account level
#
# RECOMMENDATION
# - Run initially with $WhatIfMode = $true
# - Validate the target file list before enabling deletion
################################################################################################################

################################################################################################################
# CONFIGURATION
################################################################################################################

# Azure
$SubscriptionId     = "00000000-0000-0000-0000-000000000000"
$ResourceGroupName  = "rg-storage-prod"
$StorageAccountName = "stfilesprod01"

# Share handling
$UseMultipleShares = $true
$SingleShareName   = "fslogix"
$ShareNames = @(
    "fslogix-a",
    "fslogix-b",
    "fslogix-c"
)

# File matching
$TargetExtension = ".vhdx"
$RetentionDays   = 90

# Behaviour / safety
$WhatIfMode                = $true
$DeleteEmptyDirectories    = $true
$ContinueOnDeleteFailure   = $true
$ExcludedPathFragments     = @(
    # Example:
    # "/do-not-touch/",
    # "/archive/"
)

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

function Get-ShareList {
    if ($UseMultipleShares) {
        $shares = $ShareNames |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() }

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

function Get-StorageContextFromConnectedAccount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StorageAccountName
    )

    try {
        return New-AzStorageContext `
            -StorageAccountName $StorageAccountName `
            -UseConnectedAccount `
            -ErrorAction Stop
    }
    catch {
        throw "Failed to create storage context using connected account for storage account '$StorageAccountName'. Ensure the managed identity has Azure Files data-plane permissions."
    }
}

function Test-PathExcluded {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    foreach ($fragment in $ExcludedPathFragments) {
        if ([string]::IsNullOrWhiteSpace($fragment)) {
            continue
        }

        if ($Path.ToLowerInvariant().Contains($fragment.ToLowerInvariant())) {
            return $true
        }
    }

    return $false
}

function Get-ChildItemsRecursiveFromShare {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShareName,

        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$Context
    )

    $results = New-Object System.Collections.Generic.List[object]
    $dirsToProcess = New-Object System.Collections.Generic.Queue[object]

    $rootDir = Get-AzStorageFile -ShareName $ShareName -Path "." -Context $Context -ErrorAction Stop
    $dirsToProcess.Enqueue($rootDir)

    while ($dirsToProcess.Count -gt 0) {
        $currentDir = $dirsToProcess.Dequeue()

        $children = $currentDir | Get-AzStorageFile -ErrorAction Stop

        foreach ($child in $children) {
            $results.Add($child)

            if ($child.GetType().Name -eq "AzureStorageFileDirectory") {
                $dirsToProcess.Enqueue($child)
            }
        }
    }

    return $results
}

function Get-ItemRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    if ($Item.PSObject.Properties.Match("CloudFileDirectory").Count -gt 0 -and $Item.CloudFileDirectory) {
        return [string]$Item.CloudFileDirectory.Name
    }

    if ($Item.PSObject.Properties.Match("CloudFile").Count -gt 0 -and $Item.CloudFile) {
        return [string]$Item.CloudFile.Name
    }

    if ($Item.PSObject.Properties.Match("ShareFileClient").Count -gt 0 -and $Item.ShareFileClient) {
        return [string]$Item.ShareFileClient.Path
    }

    if ($Item.PSObject.Properties.Match("ShareDirectoryClient").Count -gt 0 -and $Item.ShareDirectoryClient) {
        return [string]$Item.ShareDirectoryClient.Path
    }

    if ($Item.PSObject.Properties.Match("Name").Count -gt 0) {
        return [string]$Item.Name
    }

    return ""
}

function Get-ItemLastModifiedUtc {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    $candidates = @(
        $Item.LastModified,
        $Item.Properties.LastModified,
        $Item.ListFileProperties.LastModified
    ) | Where-Object { $null -ne $_ }

    foreach ($candidate in $candidates) {
        try {
            return ([datetime]$candidate).ToUniversalTime()
        }
        catch {
            continue
        }
    }

    return $null
}

function Remove-ShareFileByPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShareName,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$Context
    )

    Remove-AzStorageFile `
        -ShareName $ShareName `
        -Path $Path `
        -Context $Context `
        -Force `
        -ErrorAction Stop | Out-Null
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
    $SharesToProcess = Get-ShareList
    $CutoffUtc       = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays)
    $StorageContext  = Get-StorageContextFromConnectedAccount -StorageAccountName $StorageAccountName

    Write-Log "Storage account: $StorageAccountName"
    Write-Log "Resource group: $ResourceGroupName"
    Write-Log "Use multiple shares: $UseMultipleShares"
    Write-Log "Target extension: $TargetExtension"
    Write-Log "Retention days: $RetentionDays"
    Write-Log ("Cutoff UTC: " + $CutoffUtc.ToString("yyyy-MM-dd HH:mm:ss 'UTC'"))
    Write-Log "WhatIf mode: $WhatIfMode"
    Write-Log "Delete empty directories: $DeleteEmptyDirectories"
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

        $summary = [ordered]@{
            ShareName             = $ShareName
            EnumeratedItems       = 0
            EnumeratedFiles       = 0
            CandidateFiles        = 0
            DeletedFiles          = 0
            FailedDeletes         = 0
            SkippedExcludedPaths  = 0
            SkippedNoLastModified = 0
        }

        $items = Get-ChildItemsRecursiveFromShare `
            -ShareName $ShareName `
            -Context $StorageContext

        $summary.EnumeratedItems = $items.Count

        $files = $items | Where-Object { $_.GetType().Name -eq "AzureStorageFile" }
        $summary.EnumeratedFiles = ($files | Measure-Object).Count

        Write-Log "Enumerated items: $($summary.EnumeratedItems)" $ShareName
        Write-Log "Enumerated files: $($summary.EnumeratedFiles)" $ShareName

        foreach ($file in $files) {
            $relativePath = Get-ItemRelativePath -Item $file

            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                Write-Log "Skipping file because path could not be determined." $ShareName
                continue
            }

            if (Test-PathExcluded -Path $relativePath) {
                $summary.SkippedExcludedPaths++
                Write-Log "Skipping excluded path: $relativePath" $ShareName
                continue
            }

            if (-not $relativePath.ToLowerInvariant().EndsWith($TargetExtension.ToLowerInvariant())) {
                continue
            }

            $lastModifiedUtc = Get-ItemLastModifiedUtc -Item $file

            if ($null -eq $lastModifiedUtc) {
                $summary.SkippedNoLastModified++
                Write-Log "Skipping candidate because LastModified could not be determined: $relativePath" $ShareName
                continue
            }

            if ($lastModifiedUtc -ge $CutoffUtc) {
                continue
            }

            $summary.CandidateFiles++

            $ageDays = [math]::Floor((((Get-Date).ToUniversalTime()) - $lastModifiedUtc).TotalDays)

            Write-Log ("Candidate found: {0}" -f $relativePath) $ShareName
            Write-Log ("Last modified UTC: {0}" -f $lastModifiedUtc.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")) $ShareName
            Write-Log ("Age in days: {0}" -f $ageDays) $ShareName

            if ($WhatIfMode) {
                Write-Log "WhatIfMode enabled. File would be deleted." $ShareName
                continue
            }

            try {
                Remove-ShareFileByPath `
                    -ShareName $ShareName `
                    -Path $relativePath `
                    -Context $StorageContext

                $summary.DeletedFiles++
                Write-Log "Deleted file successfully." $ShareName
            }
            catch {
                $summary.FailedDeletes++
                Write-Log "Delete failed for path: $relativePath" $ShareName

                if ($ContinueOnDeleteFailure) {
                    Write-Log ("Continuing after delete failure: " + $_.Exception.Message) $ShareName
                }
                else {
                    throw
                }
            }
        }

        Write-Log "-------------------------------- SUMMARY --------------------------------" $ShareName
        Write-Log "Enumerated items: $($summary.EnumeratedItems)" $ShareName
        Write-Log "Enumerated files: $($summary.EnumeratedFiles)" $ShareName
        Write-Log "Candidate files older than $RetentionDays days: $($summary.CandidateFiles)" $ShareName
        Write-Log "Deleted files: $($summary.DeletedFiles)" $ShareName
        Write-Log "Failed deletes: $($summary.FailedDeletes)" $ShareName
        Write-Log "Skipped excluded paths: $($summary.SkippedExcludedPaths)" $ShareName
        Write-Log "Skipped due to unknown LastModified: $($summary.SkippedNoLastModified)" $ShareName
        Write-Log "Run completed for share" $ShareName
    }
    catch {
        Fail-Step "PROCESS_SHARE" $_ $ShareName
    }
}

################################################################################################################
# COMPLETE
################################################################################################################

Write-Log "Runbook completed"
