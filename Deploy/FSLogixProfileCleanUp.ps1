<#
 README
 © Phoenix Software 2026
 Developed by Aiden Wright

 PURPOSE
 - Connect to Azure using the Automation Account managed identity
 - Traverse one or more Azure File Shares recursively
 - Identify vhdx files whose LastModified date is older than the configured retention period
 - Delete matching files, or log only when WhatIfMode is enabled

 REQUIRED RBAC
 - Management plane access to the storage account resource
 - Data plane access to Azure Files sufficient to list and delete files
 - Storage File Data SMB Share Contributor & Storage Account Contributor at the Storage Account level

 RECOMMENDATION
 - Run initially with $WhatIfMode = $true
 - Validate the target file list before enabling deletion
#>

################################################################################################################
# CONFIGURATION
################################################################################################################

$SubscriptionId     = ""
$ResourceGroupName  = "rg-avd"
$StorageAccountName = ""

$UseMultipleShares = $true
$SingleShareName   = "fslogix"
$ShareNames = @(
    "profilesdesktop",
    "profilesra"
)

$TargetExtension = ".vhdx"
$RetentionDays   = 0

$WhatIfMode              = $false
$DeleteEmptyDirectories  = $true
$ContinueOnDeleteFailure = $true
$ExcludedPathFragments   = @()

$StorageApiVersion = "2021-12-02"

################################################################################################################
# MODULES
################################################################################################################


Import-Module Az.Accounts -RequiredVersion 2.15.0 -Force
Import-Module Az.Storage  -RequiredVersion 6.1.0  -Force

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

function Join-FilePath {
    param(
        [string]$Parent,
        [string]$Child
    )

    if ([string]::IsNullOrWhiteSpace($Parent)) {
        return $Child
    }

    return ($Parent.TrimEnd("/") + "/" + $Child.TrimStart("/"))
}

function ConvertTo-EscapedAzurePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    return (($Path.Trim("/") -split "/" | ForEach-Object {
        [System.Uri]::EscapeDataString($_)
    }) -join "/")
}

function Test-PathExcluded {
    param([string]$Path)

    foreach ($fragment in $ExcludedPathFragments) {
        if (-not [string]::IsNullOrWhiteSpace($fragment)) {
            if ($Path.ToLowerInvariant().Contains($fragment.ToLowerInvariant())) {
                return $true
            }
        }
    }

    return $false
}

function ConvertTo-CleanXml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $cleanContent = $Content

    # Remove UTF-8 BOM if returned as visible characters or actual BOM.
    $cleanContent = $cleanContent.TrimStart([char]0xFEFF)
    $cleanContent = $cleanContent -replace "^\u00EF\u00BB\u00BF", ""
    $cleanContent = $cleanContent -replace "^ï»¿", ""
    $cleanContent = $cleanContent.TrimStart()

    $xmlDocument = New-Object System.Xml.XmlDocument
    $xmlDocument.PreserveWhitespace = $false
    $xmlDocument.LoadXml($cleanContent)

    return $xmlDocument
}

################################################################################################################
# STORAGE REST AUTH
################################################################################################################

function Get-StorageAccountKeyValue {
    param(
        [string]$ResourceGroupName,
        [string]$StorageAccountName
    )

    return (Get-AzStorageAccountKey `
        -ResourceGroupName $ResourceGroupName `
        -Name $StorageAccountName `
        -ErrorAction Stop)[0].Value
}

function Get-CanonicalizedResource {
    param(
        [string]$StorageAccountName,
        [System.Uri]$Uri
    )

    $canonicalizedResource = "/" + $StorageAccountName + $Uri.AbsolutePath

    if (-not [string]::IsNullOrWhiteSpace($Uri.Query)) {
        $query = $Uri.Query.TrimStart("?")
        $queryPairs = @{}

        foreach ($part in ($query -split "&")) {
            if ([string]::IsNullOrWhiteSpace($part)) {
                continue
            }

            $split = $part -split "=", 2
            $name = [System.Uri]::UnescapeDataString($split[0]).ToLowerInvariant()

            if ($split.Count -gt 1) {
                $value = [System.Uri]::UnescapeDataString($split[1])
            }
            else {
                $value = ""
            }

            if (-not $queryPairs.ContainsKey($name)) {
                $queryPairs[$name] = New-Object System.Collections.Generic.List[string]
            }

            $queryPairs[$name].Add($value)
        }

        foreach ($name in ($queryPairs.Keys | Sort-Object)) {
            $values = $queryPairs[$name] | Sort-Object
            $canonicalizedResource += "`n${name}:" + ($values -join ",")
        }
    }

    return $canonicalizedResource
}

function New-StorageSharedKeyHeaders {
    param(
        [string]$Method,
        [string]$StorageAccountName,
        [string]$StorageAccountKey,
        [string]$Uri,
        [string]$StorageApiVersion
    )

    $requestDate = [DateTime]::UtcNow.ToString("R", [Globalization.CultureInfo]::InvariantCulture)
    $uriObject = [System.Uri]$Uri

    $canonicalizedHeaders =
        "x-ms-date:$requestDate`n" +
        "x-ms-version:$StorageApiVersion`n"

    $canonicalizedResource = Get-CanonicalizedResource `
        -StorageAccountName $StorageAccountName `
        -Uri $uriObject

    $stringToSign =
        $Method.ToUpperInvariant() + "`n" +
        "`n" +
        "`n" +
        "`n" +
        "`n" +
        "`n" +
        "`n" +
        "`n" +
        "`n" +
        "`n" +
        "`n" +
        "`n" +
        $canonicalizedHeaders +
        $canonicalizedResource

    $keyBytes = [Convert]::FromBase64String($StorageAccountKey)
    $messageBytes = [Text.Encoding]::UTF8.GetBytes($stringToSign)

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes

    $signature = [Convert]::ToBase64String($hmac.ComputeHash($messageBytes))

    return @{
        "x-ms-date"     = $requestDate
        "x-ms-version"  = $StorageApiVersion
        "Authorization" = "SharedKey ${StorageAccountName}:$signature"
    }
}

function Invoke-AzureFileRest {
    param(
        [string]$Method,
        [string]$Uri,
        [string]$StorageAccountName,
        [string]$StorageAccountKey,
        [string]$StorageApiVersion
    )

    $headers = New-StorageSharedKeyHeaders `
        -Method $Method `
        -StorageAccountName $StorageAccountName `
        -StorageAccountKey $StorageAccountKey `
        -Uri $Uri `
        -StorageApiVersion $StorageApiVersion

    return Invoke-WebRequest `
        -Method $Method `
        -Uri $Uri `
        -Headers $headers `
        -UseBasicParsing `
        -ErrorAction Stop
}

################################################################################################################
# AZURE FILES REST
################################################################################################################

function Get-AzureFileListUri {
    param(
        [string]$StorageAccountName,
        [string]$ShareName,
        [string]$DirectoryPath = "",
        [string]$Marker = ""
    )

    $base = "https://$StorageAccountName.file.core.windows.net/$ShareName"

    if (-not [string]::IsNullOrWhiteSpace($DirectoryPath)) {
        $base += "/" + (ConvertTo-EscapedAzurePath -Path $DirectoryPath)
    }

    $query = "restype=directory&comp=list"

    if (-not [string]::IsNullOrWhiteSpace($Marker)) {
        $query += "&marker=" + [System.Uri]::EscapeDataString($Marker)
    }

    return "$base`?$query"
}

function Get-AzureFileUri {
    param(
        [string]$StorageAccountName,
        [string]$ShareName,
        [string]$FilePath
    )

    return "https://$StorageAccountName.file.core.windows.net/$ShareName/" + (ConvertTo-EscapedAzurePath -Path $FilePath)
}

function Get-AzureFileDirectoryItems {
    param(
        [string]$ShareName,
        [string]$DirectoryPath = "",
        [string]$StorageAccountName,
        [string]$StorageAccountKey,
        [string]$StorageApiVersion
    )

    $allItems = New-Object System.Collections.Generic.List[object]
    $marker = ""

    do {
        $uri = Get-AzureFileListUri `
            -StorageAccountName $StorageAccountName `
            -ShareName $ShareName `
            -DirectoryPath $DirectoryPath `
            -Marker $marker

        $response = Invoke-AzureFileRest `
            -Method "GET" `
            -Uri $uri `
            -StorageAccountName $StorageAccountName `
            -StorageAccountKey $StorageAccountKey `
            -StorageApiVersion $StorageApiVersion

        $xml = ConvertTo-CleanXml -Content ([string]$response.Content)

        if ($xml.EnumerationResults.Entries.Directory) {
            foreach ($directory in $xml.EnumerationResults.Entries.Directory) {
                $path = Join-FilePath -Parent $DirectoryPath -Child ([string]$directory.Name)

                $allItems.Add([pscustomobject]@{
                    Type = "Directory"
                    Name = [string]$directory.Name
                    Path = $path
                })
            }
        }

        if ($xml.EnumerationResults.Entries.File) {
            foreach ($file in $xml.EnumerationResults.Entries.File) {
                $path = Join-FilePath -Parent $DirectoryPath -Child ([string]$file.Name)

                $allItems.Add([pscustomobject]@{
                    Type = "File"
                    Name = [string]$file.Name
                    Path = $path
                })
            }
        }

        $marker = [string]$xml.EnumerationResults.NextMarker
    }
    while (-not [string]::IsNullOrWhiteSpace($marker))

    return $allItems
}

function Get-AzureFileItemsRecursive {
    param(
        [string]$ShareName,
        [string]$StorageAccountName,
        [string]$StorageAccountKey,
        [string]$StorageApiVersion
    )

    $results = New-Object System.Collections.Generic.List[object]
    $dirsToProcess = New-Object System.Collections.Generic.Queue[string]

    $dirsToProcess.Enqueue("")

    while ($dirsToProcess.Count -gt 0) {
        $currentDir = $dirsToProcess.Dequeue()

        $items = Get-AzureFileDirectoryItems `
            -ShareName $ShareName `
            -DirectoryPath $currentDir `
            -StorageAccountName $StorageAccountName `
            -StorageAccountKey $StorageAccountKey `
            -StorageApiVersion $StorageApiVersion

        foreach ($item in $items) {
            $results.Add($item)

            if ($item.Type -eq "Directory") {
                $dirsToProcess.Enqueue($item.Path)
            }
        }
    }

    return $results
}

function Get-AzureFileLastModifiedUtc {
    param(
        [string]$ShareName,
        [string]$FilePath,
        [string]$StorageAccountName,
        [string]$StorageAccountKey,
        [string]$StorageApiVersion
    )

    $uri = Get-AzureFileUri `
        -StorageAccountName $StorageAccountName `
        -ShareName $ShareName `
        -FilePath $FilePath

    $response = Invoke-AzureFileRest `
        -Method "HEAD" `
        -Uri $uri `
        -StorageAccountName $StorageAccountName `
        -StorageAccountKey $StorageAccountKey `
        -StorageApiVersion $StorageApiVersion

    if ($response.Headers["Last-Modified"]) {
        return ([datetime]$response.Headers["Last-Modified"]).ToUniversalTime()
    }

    return $null
}

function Remove-AzureFileByRest {
    param(
        [string]$ShareName,
        [string]$FilePath,
        [string]$StorageAccountName,
        [string]$StorageAccountKey,
        [string]$StorageApiVersion
    )

    $uri = Get-AzureFileUri `
        -StorageAccountName $StorageAccountName `
        -ShareName $ShareName `
        -FilePath $FilePath

    Invoke-AzureFileRest `
        -Method "DELETE" `
        -Uri $uri `
        -StorageAccountName $StorageAccountName `
        -StorageAccountKey $StorageAccountKey `
        -StorageApiVersion $StorageApiVersion | Out-Null
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
    $CutoffUtc = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays)

    Write-Log "Retrieving storage account key"

    $StorageAccountKey = Get-StorageAccountKeyValue `
        -ResourceGroupName $ResourceGroupName `
        -StorageAccountName $StorageAccountName

    Write-Log "Storage account key retrieved successfully"

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

        $items = Get-AzureFileItemsRecursive `
            -ShareName $ShareName `
            -StorageAccountName $StorageAccountName `
            -StorageAccountKey $StorageAccountKey `
            -StorageApiVersion $StorageApiVersion

        $summary.EnumeratedItems = ($items | Measure-Object).Count

        $files = $items | Where-Object { $_.Type -eq "File" }
        $summary.EnumeratedFiles = ($files | Measure-Object).Count

        Write-Log "Enumerated items: $($summary.EnumeratedItems)" $ShareName
        Write-Log "Enumerated files: $($summary.EnumeratedFiles)" $ShareName

        foreach ($file in $files) {
            $relativePath = [string]$file.Path

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

            Write-Log ("Checking candidate file: {0}" -f $relativePath) $ShareName

            try {
                $lastModifiedUtc = Get-AzureFileLastModifiedUtc `
                    -ShareName $ShareName `
                    -FilePath $relativePath `
                    -StorageAccountName $StorageAccountName `
                    -StorageAccountKey $StorageAccountKey `
                    -StorageApiVersion $StorageApiVersion
            }
            catch {
                $summary.SkippedNoLastModified++
                Write-Log "Skipping candidate because LastModified could not be determined: $relativePath" $ShareName
                Write-Log ("LastModified lookup error: " + $_.Exception.Message) $ShareName
                continue
            }

            if ($null -eq $lastModifiedUtc) {
                $summary.SkippedNoLastModified++
                Write-Log "Skipping candidate because LastModified could not be determined: $relativePath" $ShareName
                continue
            }

            Write-Log ("Last modified UTC discovered: {0}" -f $lastModifiedUtc.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")) $ShareName

            if ($lastModifiedUtc -ge $CutoffUtc) {
                Write-Log "Skipping candidate because it is newer than the cutoff: $relativePath" $ShareName
                continue
            }

            $summary.CandidateFiles++
            $ageDays = [math]::Floor((((Get-Date).ToUniversalTime()) - $lastModifiedUtc).TotalDays)

            Write-Log ("Candidate found: {0}" -f $relativePath) $ShareName
            Write-Log ("Age in days: {0}" -f $ageDays) $ShareName

            if ($WhatIfMode) {
                Write-Log "WhatIfMode enabled. File would be deleted." $ShareName
                continue
            }

            try {
                Remove-AzureFileByRest `
                    -ShareName $ShareName `
                    -FilePath $relativePath `
                    -StorageAccountName $StorageAccountName `
                    -StorageAccountKey $StorageAccountKey `
                    -StorageApiVersion $StorageApiVersion

                $summary.DeletedFiles++
                Write-Log "Deleted file successfully: $relativePath" $ShareName
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

Write-Log "Runbook completed"
