<# 
README
© Phoenix Software 2026
Developed by Aiden Wright

Runbook:
    AVDHybridImageSync

Purpose:
    Syncs the latest Azure Compute Gallery image version to a local/UNC Hyper-V template repository
    for Azure Virtual Desktop Hybrid session host deployments.

High-level flow:
    1. Authenticate to Azure using the Automation Account managed identity.
    2. Find the latest Azure Compute Gallery image version.
    3. Compare it with the current synced version stored in an Automation Variable.
    4. If a newer version exists, create a temporary managed disk from the gallery image version.
    5. Export the managed disk using a temporary SAS URL.
    6. Download the VHD to local staging on the Hybrid Worker using AzCopy.
    7. Validate and optionally convert the VHD to VHDX.
    8. Promote the finished template to the final template repository.
    9. Update Automation Variables.
    10. Revoke disk SAS access, delete the temporary managed disk, and clean up staging.

Runbook type:
    PowerShell 5.1

Important:
    This runbook must run on a Hybrid Runbook Worker.
    The Hybrid Worker must have access to both:
        - Local staging path
        - Final template repository path

Required Automation Variables:
    AVDHybrid-CurrentGalleryVersion
    AVDHybrid-CurrentTemplatePath
    AVDHybrid-LastSuccessfulSync
    AVDHybrid-ImageSyncStatus
    AVDHybrid-CurrentTemplateJson

Recommended managed identity permissions:
    - Reader on the Azure Compute Gallery resource group.
    - Contributor on the temporary managed disk resource group.
    - Permission to read/update Automation Variables from the runbook.

Hybrid Worker requirements:
    - Az.Accounts module.
    - Az.Compute module.
    - Hyper-V PowerShell module if converting or validating VHD/VHDX.
    - AzCopy installed, or allow this runbook to install it automatically.
#>

################################################################################################################
# CONFIGURATION
################################################################################################################

# Azure
$SubscriptionId                 = ""
$GalleryResourceGroupName       = "rg-avd-images-uks"
$GalleryName                    = ""
$GalleryImageDefinitionName     = "WINDOWS11-Hybrid-Post"
$ExportLocation                 = "uksouth"

# Temporary managed disk
# Leave blank to use the gallery resource group.
$TempDiskResourceGroupName      = ""
$TempDiskSkuName                = "Standard_LRS"
$DiskSasDurationSeconds         = 43200 # 12 hours

# Local staging on Hybrid Worker
# Use a local disk with enough free space for the exported VHD and converted VHDX.
$LocalStagingRootPath           = "C:\AVDHybridImageSync\Staging"

# AzCopy
$UseAzCopyForDownload           = $true
$AzCopyPath                     = "C:\Tools\AzCopy\azcopy.exe"
$AutoInstallAzCopy              = $true
$AzCopyInstallRoot              = "C:\Tools\AzCopy"

# Download fallback behaviour
# These are only used if AzCopy is disabled.
$DownloadRetryCount             = 3
$DownloadRetryDelaySeconds      = 30

# Final Hyper-V template repository
# This can be local or UNC.
$TemplateRootPath               = ""
$TemplatePrefix                 = "avd-hybrid-win11-enterprise"

# Template handling
$ConvertToVhdx                  = $true
$VhdxType                       = "Fixed" # Dynamic or Fixed
$ValidateWithHyperVModule       = $true
$MinimumTemplateSizeGiB         = 5

# Version handling
$RespectExcludeFromLatest       = $false
$ForceSync                      = $false
$OverwriteExistingVersion       = $false

# Safety / behaviour
$DeleteSourceVhdAfterConvert    = $true
$KeepFailedStaging              = $false
$WhatIfMode                     = $true

# Automation Variable names
$CurrentGalleryVersionVariableName = "AVDHybrid-CurrentGalleryVersion"
$CurrentTemplatePathVariableName   = "AVDHybrid-CurrentTemplatePath"
$LastSuccessfulSyncVariableName    = "AVDHybrid-LastSuccessfulSync"
$ImageSyncStatusVariableName       = "AVDHybrid-ImageSyncStatus"
$CurrentTemplateJsonVariableName   = "AVDHybrid-CurrentTemplateJson"

################################################################################################################
# MODULES
################################################################################################################

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Compute  -ErrorAction Stop

################################################################################################################
# LOGGING / ERROR HANDLING
################################################################################################################

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Stage = ""
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    if ([string]::IsNullOrWhiteSpace($Stage)) {
        Write-Output "[$timestamp] $Message"
    }
    else {
        Write-Output "[$timestamp] [$Stage] $Message"
    }
}

function Fail-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Step,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-Log "================ ERROR BEGIN ================"
    Write-Log "FAILED at [$Step]"

    if ($ErrorRecord.Exception) {
        Write-Log ("Message: " + $ErrorRecord.Exception.Message)

        if ($ErrorRecord.Exception.InnerException) {
            Write-Log ("InnerException: " + $ErrorRecord.Exception.InnerException.Message)
        }
    }

    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.Line) {
        Write-Log ("Invocation line: " + $ErrorRecord.InvocationInfo.Line)
    }

    Write-Log (($ErrorRecord | Format-List * -Force | Out-String))
    Write-Log "================ ERROR END =================="
}

################################################################################################################
# HELPER FUNCTIONS
################################################################################################################

function New-SafeName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [int]$MaxLength = 80
    )

    $safeName = ($Name -replace '[^a-zA-Z0-9-]', '-').Trim("-")

    while ($safeName -match "--") {
        $safeName = $safeName -replace "--", "-"
    }

    if ($safeName.Length -gt $MaxLength) {
        $safeName = $safeName.Substring(0, $MaxLength).Trim("-")
    }

    return $safeName.ToLower()
}

function Compare-VersionName {
    param(
        [string]$A,
        [string]$B
    )

    if ([string]::IsNullOrWhiteSpace($A) -and [string]::IsNullOrWhiteSpace($B)) {
        return 0
    }

    if ([string]::IsNullOrWhiteSpace($A)) {
        return -1
    }

    if ([string]::IsNullOrWhiteSpace($B)) {
        return 1
    }

    $versionA = $null
    $versionB = $null

    $parsedA = [System.Version]::TryParse($A, [ref]$versionA)
    $parsedB = [System.Version]::TryParse($B, [ref]$versionB)

    if ($parsedA -and $parsedB) {
        return $versionA.CompareTo($versionB)
    }

    if ($parsedA -and -not $parsedB) {
        Write-Log "Current version '$B' is not a valid version. Treating latest version '$A' as newer." "COMPARE"
        return 1
    }

    if (-not $parsedA -and $parsedB) {
        Write-Log "Latest version '$A' is not a valid version but current version '$B' is valid. Falling back to string comparison." "COMPARE"
    }

    return [string]::Compare($A, $B, $true, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-AutomationVariableSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        return Get-AutomationVariable -Name $Name -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "Automation Variable '$Name' could not be read. Returning empty value." "AUTOMATION"
        return $null
    }
}

function Set-AutomationVariableSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($WhatIfMode) {
        Write-Log "WhatIfMode enabled. Would update Automation Variable '$Name' to '$Value'." "AUTOMATION"
        return
    }

    Set-AutomationVariable -Name $Name -Value $Value -ErrorAction Stop
    Write-Log "Updated Automation Variable '$Name'." "AUTOMATION"
}

function New-DirectoryIfMissing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Stage = "INIT"
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path value is empty."
    }

    if (-not (Test-Path $Path)) {
        if ($WhatIfMode) {
            Write-Log "WhatIfMode enabled. Would create directory: $Path" $Stage
        }
        else {
            New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Log "Created directory: $Path" $Stage
        }
    }
}

function New-TemplateDirectories {
    if ([string]::IsNullOrWhiteSpace($TemplateRootPath)) {
        throw "TemplateRootPath is empty."
    }

    if ([string]::IsNullOrWhiteSpace($LocalStagingRootPath)) {
        throw "LocalStagingRootPath is empty."
    }

    if ($TemplateRootPath -match '^\\\\[^\\]+\\[^\\]+$') {
        throw "TemplateRootPath points to the root of a UNC share: '$TemplateRootPath'. Use a subfolder such as '\\server\share\ImageTemplates'."
    }

    $paths = @(
        @{
            Name = "TemplateRootPath"
            Path = $TemplateRootPath
        },
        @{
            Name = "TemplateStagingPath"
            Path = Join-Path $TemplateRootPath "_staging"
        },
        @{
            Name = "TemplateVersionsPath"
            Path = Join-Path $TemplateRootPath "Versions"
        },
        @{
            Name = "TemplateCurrentPath"
            Path = Join-Path $TemplateRootPath "Current"
        },
        @{
            Name = "LocalStagingRootPath"
            Path = $LocalStagingRootPath
        }
    )

    foreach ($item in $paths) {
        if ([string]::IsNullOrWhiteSpace($item.Path)) {
            throw "$($item.Name) resolved to an empty path."
        }

        Write-Log "Checking directory [$($item.Name)]: $($item.Path)" "INIT"
        New-DirectoryIfMissing -Path $item.Path -Stage "INIT"
    }
}

function Test-FreeSpace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int64]$RequiredBytes
    )

    $root = [System.IO.Path]::GetPathRoot($Path)

    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Unable to determine path root for '$Path'."
    }

    $driveInfo = New-Object System.IO.DriveInfo($root)

    $freeGiB = [math]::Round(($driveInfo.AvailableFreeSpace / 1GB), 2)
    $requiredGiB = [math]::Round(($RequiredBytes / 1GB), 2)

    Write-Log "Path root: $root" "SPACE"
    Write-Log "Available free space: $freeGiB GiB" "SPACE"
    Write-Log "Required free space: $requiredGiB GiB" "SPACE"

    if ($driveInfo.AvailableFreeSpace -lt $RequiredBytes) {
        throw "Not enough free space on $root. Available: $freeGiB GiB. Required: $requiredGiB GiB."
    }
}

################################################################################################################
# AZURE IMAGE FUNCTIONS
################################################################################################################

function Get-LatestGalleryImageVersion {
    Write-Log "Retrieving gallery image versions..." "GALLERY"

    $versions = Get-AzGalleryImageVersion `
        -ResourceGroupName $GalleryResourceGroupName `
        -GalleryName $GalleryName `
        -GalleryImageDefinitionName $GalleryImageDefinitionName `
        -ErrorAction Stop

    if (-not $versions) {
        throw "No image versions found for gallery '$GalleryName', image definition '$GalleryImageDefinitionName'."
    }

    $eligibleVersions = @($versions)

    if ($RespectExcludeFromLatest) {
        $eligibleVersions = @(
            $versions | Where-Object {
                $excludeFromLatest = $false

                if ($_.PublishingProfile -and ($_.PublishingProfile.PSObject.Properties.Name -contains "ExcludeFromLatest")) {
                    $excludeFromLatest = [bool]$_.PublishingProfile.ExcludeFromLatest
                }

                return (-not $excludeFromLatest)
            }
        )

        if (-not $eligibleVersions -or $eligibleVersions.Count -eq 0) {
            throw "All gallery image versions appear to be excluded from latest."
        }
    }

    $sortableVersions = foreach ($version in $eligibleVersions) {
        $parsedVersion = $null
        $isVersion = [System.Version]::TryParse([string]$version.Name, [ref]$parsedVersion)

        if (-not $isVersion) {
            $parsedVersion = [System.Version]"0.0.0"
        }

        [PSCustomObject]@{
            ImageVersion  = $version
            ParsedVersion = $parsedVersion
            Name          = [string]$version.Name
        }
    }

    $latest = ($sortableVersions | Sort-Object ParsedVersion, Name -Descending | Select-Object -First 1).ImageVersion

    if (-not $latest) {
        throw "Unable to determine latest gallery image version."
    }

    Write-Log "Latest eligible gallery image version: $($latest.Name)" "GALLERY"
    Write-Log "Latest image version resource ID: $($latest.Id)" "GALLERY"

    return $latest
}

################################################################################################################
# AZCOPY / DOWNLOAD FUNCTIONS
################################################################################################################

function Install-AzCopyIfRequired {
    if (-not $UseAzCopyForDownload) {
        return
    }

    if (Test-Path $AzCopyPath) {
        Write-Log "AzCopy found: $AzCopyPath" "AZCOPY"
        & $AzCopyPath --version
        return
    }

    if (-not $AutoInstallAzCopy) {
        throw "AzCopy not found at '$AzCopyPath' and AutoInstallAzCopy is disabled."
    }

    Write-Log "AzCopy not found. AutoInstallAzCopy is enabled." "AZCOPY"
    Write-Log "Installing AzCopy to: $AzCopyInstallRoot" "AZCOPY"

    if (-not (Test-Path $AzCopyInstallRoot)) {
        New-Item -Path $AzCopyInstallRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    $zipPath = Join-Path $AzCopyInstallRoot "azcopy.zip"
    $extractPath = Join-Path $AzCopyInstallRoot "Extracted"

    if (Test-Path $zipPath) {
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $extractPath) {
        Remove-Item -Path $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Invoke-WebRequest `
        -Uri "https://aka.ms/downloadazcopy-v10-windows" `
        -OutFile $zipPath `
        -UseBasicParsing `
        -ErrorAction Stop

    Expand-Archive `
        -Path $zipPath `
        -DestinationPath $extractPath `
        -Force `
        -ErrorAction Stop

    $azCopyExe = Get-ChildItem `
        -Path $extractPath `
        -Recurse `
        -Filter "azcopy.exe" |
        Select-Object -First 1

    if (-not $azCopyExe) {
        throw "AzCopy download/extraction completed, but azcopy.exe was not found."
    }

    Copy-Item `
        -Path $azCopyExe.FullName `
        -Destination $AzCopyPath `
        -Force `
        -ErrorAction Stop

    if (-not (Test-Path $AzCopyPath)) {
        throw "AzCopy install failed. Expected file not found: $AzCopyPath"
    }

    Write-Log "AzCopy installed successfully." "AZCOPY"
    & $AzCopyPath --version
}

function Download-FileFromUri {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $destinationFolder = Split-Path -Path $DestinationPath -Parent

    if (-not (Test-Path $destinationFolder)) {
        New-Item -Path $destinationFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    if (Test-Path $DestinationPath) {
        Write-Log "Removing existing partial file: $DestinationPath" "DOWNLOAD"
        Remove-Item -Path $DestinationPath -Force -ErrorAction Stop
    }

    if ($UseAzCopyForDownload) {
        Install-AzCopyIfRequired

        if (-not (Test-Path $AzCopyPath)) {
            throw "AzCopyPath is configured but azcopy.exe was not found at: $AzCopyPath"
        }

        Write-Log "Using AzCopy for large VHD download." "DOWNLOAD"
        Write-Log "AzCopy path: $AzCopyPath" "DOWNLOAD"
        Write-Log "Destination: $DestinationPath" "DOWNLOAD"

        $azCopyLogFolder = Join-Path $destinationFolder "_azcopylogs"

        if (-not (Test-Path $azCopyLogFolder)) {
            New-Item -Path $azCopyLogFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        $env:AZCOPY_LOG_LOCATION = $azCopyLogFolder
        $env:AZCOPY_JOB_PLAN_LOCATION = $azCopyLogFolder

        $azCopyArgs = @(
            "copy",
            $Uri,
            $DestinationPath,
            "--overwrite=true",
            "--check-length=true",
            "--log-level=INFO"
        )

        Write-Log "Starting AzCopy download..." "DOWNLOAD"

        & $AzCopyPath @azCopyArgs

        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            throw "AzCopy failed with exit code $exitCode. Check AzCopy logs at: $azCopyLogFolder"
        }

        if (-not (Test-Path $DestinationPath)) {
            throw "AzCopy completed but destination file was not found: $DestinationPath"
        }

        Write-Log "AzCopy download completed successfully." "DOWNLOAD"
        return
    }

    $downloadSucceeded = $false

    for ($attempt = 1; $attempt -le $DownloadRetryCount; $attempt++) {
        Write-Log "Download attempt $attempt of $DownloadRetryCount." "DOWNLOAD"
        Write-Log "Downloading VHD to local staging: $DestinationPath" "DOWNLOAD"

        try {
            try {
                Import-Module BitsTransfer -ErrorAction Stop

                Start-BitsTransfer `
                    -Source $Uri `
                    -Destination $DestinationPath `
                    -DisplayName "AVD Hybrid Image Sync" `
                    -Description "Downloading exported Azure managed disk VHD" `
                    -RetryInterval 60 `
                    -RetryTimeout 7200 `
                    -ErrorAction Stop

                Write-Log "Download completed using BITS." "DOWNLOAD"
                $downloadSucceeded = $true
                break
            }
            catch {
                Write-Log "BITS download failed. Falling back to Invoke-WebRequest." "DOWNLOAD"
                Write-Log "BITS failure: $($_.Exception.Message)" "DOWNLOAD"

                Invoke-WebRequest `
                    -Uri $Uri `
                    -OutFile $DestinationPath `
                    -UseBasicParsing `
                    -TimeoutSec 0 `
                    -ErrorAction Stop

                Write-Log "Download completed using Invoke-WebRequest." "DOWNLOAD"
                $downloadSucceeded = $true
                break
            }
        }
        catch {
            Write-Log "Download attempt $attempt failed: $($_.Exception.Message)" "DOWNLOAD"

            if (Test-Path $DestinationPath) {
                try {
                    Remove-Item -Path $DestinationPath -Force -ErrorAction SilentlyContinue
                    Write-Log "Removed failed partial download." "DOWNLOAD"
                }
                catch {
                    Write-Log "Could not remove failed partial download: $($_.Exception.Message)" "DOWNLOAD"
                }
            }

            if ($attempt -lt $DownloadRetryCount) {
                Write-Log "Waiting $DownloadRetryDelaySeconds seconds before retrying..." "DOWNLOAD"
                Start-Sleep -Seconds $DownloadRetryDelaySeconds
            }
        }
    }

    if (-not $downloadSucceeded) {
        throw "Download failed after $DownloadRetryCount attempts."
    }
}

################################################################################################################
# TEMPLATE FUNCTIONS
################################################################################################################

function Validate-TemplateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Template file does not exist: $Path"
    }

    $file = Get-Item -Path $Path -ErrorAction Stop
    $sizeGiB = [math]::Round(($file.Length / 1GB), 2)

    Write-Log "Template file: $Path" "VALIDATE"
    Write-Log "Template size: $sizeGiB GiB" "VALIDATE"

    if ($sizeGiB -lt $MinimumTemplateSizeGiB) {
        throw "Template file is smaller than the minimum expected size of $MinimumTemplateSizeGiB GiB."
    }

    if ($ValidateWithHyperVModule) {
        try {
            Import-Module Hyper-V -ErrorAction Stop

            $vhdInfo = Get-VHD -Path $Path -ErrorAction Stop

            Write-Log "VHD format: $($vhdInfo.VhdFormat)" "VALIDATE"
            Write-Log "VHD type: $($vhdInfo.VhdType)" "VALIDATE"
            Write-Log "VHD size: $([math]::Round(($vhdInfo.Size / 1GB), 2)) GiB" "VALIDATE"
            Write-Log "VHD file size: $([math]::Round(($vhdInfo.FileSize / 1GB), 2)) GiB" "VALIDATE"
        }
        catch {
            throw "Hyper-V validation failed for '$Path'. Message: $($_.Exception.Message)"
        }
    }

    Write-Log "Template validation completed successfully." "VALIDATE"
}

function Write-CurrentMetadataFile {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Metadata
    )

    $currentFolder = Join-Path $TemplateRootPath "Current"
    $metadataPath = Join-Path $currentFolder "current.json"
    $json = $Metadata | ConvertTo-Json -Depth 10

    if ($WhatIfMode) {
        Write-Log "WhatIfMode enabled. Would write metadata file: $metadataPath" "PROMOTE"
        Write-Log $json "PROMOTE"
        return
    }

    Set-Content -Path $metadataPath -Value $json -Encoding UTF8 -Force -ErrorAction Stop
    Write-Log "Updated current metadata file: $metadataPath" "PROMOTE"
}

################################################################################################################
# CLEANUP
################################################################################################################

function Invoke-Cleanup {
    Write-Log "Starting cleanup..." "CLEANUP"

    if ($script:sasGranted -and $script:tempDiskName) {
        try {
            Revoke-AzDiskAccess `
                -ResourceGroupName $TempDiskResourceGroupName `
                -DiskName $script:tempDiskName `
                -ErrorAction Stop | Out-Null

            Write-Log "Revoked temporary disk SAS access." "CLEANUP"
        }
        catch {
            Write-Log "Failed to revoke disk SAS access: $($_.Exception.Message)" "CLEANUP"
        }
    }

    if ($script:tempDiskCreated -and $script:tempDiskName) {
        try {
            Remove-AzDisk `
                -ResourceGroupName $TempDiskResourceGroupName `
                -DiskName $script:tempDiskName `
                -Force `
                -ErrorAction Stop | Out-Null

            Write-Log "Deleted temporary managed disk: $($script:tempDiskName)" "CLEANUP"
        }
        catch {
            Write-Log "Failed to delete temporary managed disk '$($script:tempDiskName)': $($_.Exception.Message)" "CLEANUP"
        }
    }

    if ($script:localStagingFolder -and (Test-Path $script:localStagingFolder)) {
        if ($script:syncSucceeded -or (-not $KeepFailedStaging)) {
            try {
                Remove-Item -Path $script:localStagingFolder -Recurse -Force -ErrorAction Stop
                Write-Log "Removed local staging folder: $($script:localStagingFolder)" "CLEANUP"
            }
            catch {
                Write-Log "Failed to remove local staging folder '$($script:localStagingFolder)': $($_.Exception.Message)" "CLEANUP"
            }
        }
        else {
            Write-Log "Keeping local staging folder for troubleshooting: $($script:localStagingFolder)" "CLEANUP"
        }
    }

    Write-Log "Cleanup complete." "CLEANUP"
}

################################################################################################################
# MAIN
################################################################################################################

$ErrorActionPreference = "Stop"

$script:latestVersion      = $null
$script:tempDiskName       = $null
$script:tempDiskCreated    = $false
$script:sasGranted         = $false
$script:syncSucceeded      = $false
$script:localStagingFolder = $null

try {
    ############################################################################################################
    # AUTHENTICATION / INITIALISATION
    ############################################################################################################

    Write-Log "Runbook starting"
    Write-Log "This runbook must run on a Hybrid Runbook Worker with access to the local template repository."
    Write-Log "WhatIf mode: $WhatIfMode"

    Write-Log "Windows identity: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" "IDENTITY"
    Write-Log "Computer name: $env:COMPUTERNAME" "IDENTITY"

    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        throw "SubscriptionId has not been configured."
    }

    if ([string]::IsNullOrWhiteSpace($GalleryResourceGroupName)) {
        throw "GalleryResourceGroupName has not been configured."
    }

    if ([string]::IsNullOrWhiteSpace($GalleryName)) {
        throw "GalleryName has not been configured."
    }

    if ([string]::IsNullOrWhiteSpace($GalleryImageDefinitionName)) {
        throw "GalleryImageDefinitionName has not been configured."
    }

    if ([string]::IsNullOrWhiteSpace($ExportLocation)) {
        throw "ExportLocation has not been configured."
    }

    if ([string]::IsNullOrWhiteSpace($TempDiskResourceGroupName)) {
        $TempDiskResourceGroupName = $GalleryResourceGroupName
    }

    Write-Log "Authenticating with managed identity..." "AUTH"

    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null

    Write-Log "Authenticated successfully." "AUTH"

    Write-Log "Initialising template repository..." "INIT"
    New-TemplateDirectories

    Write-Log "Gallery resource group: $GalleryResourceGroupName" "INIT"
    Write-Log "Gallery name: $GalleryName" "INIT"
    Write-Log "Gallery image definition: $GalleryImageDefinitionName" "INIT"
    Write-Log "Export location: $ExportLocation" "INIT"
    Write-Log "Temporary disk resource group: $TempDiskResourceGroupName" "INIT"
    Write-Log "Local staging root path: $LocalStagingRootPath" "INIT"
    Write-Log "Template root path: $TemplateRootPath" "INIT"
    Write-Log "Convert to VHDX: $ConvertToVhdx" "INIT"
    Write-Log "VHDX type: $VhdxType" "INIT"
    Write-Log "Use AzCopy for download: $UseAzCopyForDownload" "INIT"
    Write-Log "Force sync: $ForceSync" "INIT"

    ############################################################################################################
    # VERSION COMPARISON
    ############################################################################################################

    $script:latestVersion = Get-LatestGalleryImageVersion
    $latestVersionName = [string]$script:latestVersion.Name

    $currentVersion = Get-AutomationVariableSafe -Name $CurrentGalleryVersionVariableName

    if ([string]::IsNullOrWhiteSpace($currentVersion)) {
        Write-Log "Current gallery version Automation Variable is empty. First sync will be required." "COMPARE"
    }
    else {
        Write-Log "Current synced gallery version: $currentVersion" "COMPARE"
    }

    Write-Log "Latest gallery version: $latestVersionName" "COMPARE"

    $comparison = Compare-VersionName -A $latestVersionName -B $currentVersion

    if (($comparison -le 0) -and (-not $ForceSync)) {
        Write-Log "No newer image version found. No action required." "COMPARE"

        $status = "Success-NoAction | Latest=$latestVersionName | Current=$currentVersion | Checked=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Set-AutomationVariableSafe -Name $ImageSyncStatusVariableName -Value $status

        Write-Output "SUMMARY | Action=NoAction | LatestGalleryVersion=$latestVersionName | CurrentGalleryVersion=$currentVersion"
        Write-Log "Runbook complete"
        return
    }

    if ($ForceSync) {
        Write-Log "ForceSync is enabled. Sync will run even if the version is not newer." "COMPARE"
    }
    else {
        Write-Log "Newer image version found. Sync required." "COMPARE"
    }

    ############################################################################################################
    # PLAN PATHS
    ############################################################################################################

    $runId = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeDefinitionName = New-SafeName -Name $GalleryImageDefinitionName -MaxLength 40
    $safeVersionName = New-SafeName -Name $script:latestVersion.Name -MaxLength 20

    $versionsRoot = Join-Path $TemplateRootPath "Versions"
    $versionFolder = Join-Path $versionsRoot $script:latestVersion.Name

    $script:localStagingFolder = Join-Path $LocalStagingRootPath "$safeDefinitionName-$safeVersionName-$runId"

    $finalExtension = if ($ConvertToVhdx) { "vhdx" } else { "vhd" }
    $versionedTemplateName = "$TemplatePrefix-$($script:latestVersion.Name).$finalExtension"
    $versionedTemplatePath = Join-Path $versionFolder $versionedTemplateName

    Write-Log "Local staging folder: $($script:localStagingFolder)" "PLAN"
    Write-Log "Version folder: $versionFolder" "PLAN"
    Write-Log "Versioned template path: $versionedTemplatePath" "PLAN"

    if ((Test-Path $versionedTemplatePath) -and (-not $OverwriteExistingVersion)) {
        Write-Log "Template for version $($script:latestVersion.Name) already exists and OverwriteExistingVersion is false." "PLAN"
        Write-Log "Validating existing template and updating Automation Variables." "PLAN"

        Validate-TemplateFile -Path $versionedTemplatePath

        $metadata = [ordered]@{
            GalleryName                = $GalleryName
            GalleryResourceGroupName   = $GalleryResourceGroupName
            GalleryImageDefinitionName = $GalleryImageDefinitionName
            GalleryImageVersion        = $script:latestVersion.Name
            GalleryImageVersionId      = $script:latestVersion.Id
            TemplatePath               = $versionedTemplatePath
            TemplateRootPath           = $TemplateRootPath
            SyncedOn                   = (Get-Date).ToUniversalTime().ToString("o")
            SyncSource                 = "ExistingLocalTemplate"
            Runbook                    = "AVDHybridImageSync"
        }

        Write-CurrentMetadataFile -Metadata $metadata

        Set-AutomationVariableSafe -Name $CurrentGalleryVersionVariableName -Value $script:latestVersion.Name
        Set-AutomationVariableSafe -Name $CurrentTemplatePathVariableName -Value $versionedTemplatePath
        Set-AutomationVariableSafe -Name $LastSuccessfulSyncVariableName -Value (Get-Date).ToUniversalTime().ToString("o")
        Set-AutomationVariableSafe -Name $ImageSyncStatusVariableName -Value "Success-ExistingTemplate | Version=$($script:latestVersion.Name)"
        Set-AutomationVariableSafe -Name $CurrentTemplateJsonVariableName -Value (($metadata | ConvertTo-Json -Depth 10 -Compress))

        Write-Output "SUMMARY | Action=ExistingTemplatePromoted | Version=$($script:latestVersion.Name) | TemplatePath=$versionedTemplatePath"
        Write-Log "Runbook complete"
        return
    }

    if ($WhatIfMode) {
        Write-Log "WhatIfMode enabled. Sync plan only. No Azure disk, download, conversion, or variable update will be performed." "PLAN"
        Write-Log "Would create temporary managed disk from image version: $($script:latestVersion.Id)" "PLAN"
        Write-Log "Would download to local staging folder: $($script:localStagingFolder)" "PLAN"
        Write-Log "Would promote to: $versionedTemplatePath" "PLAN"

        Write-Output "SUMMARY | Action=WhatIf | Version=$($script:latestVersion.Name) | PlannedTemplatePath=$versionedTemplatePath"
        Write-Log "Runbook complete"
        return
    }

    New-DirectoryIfMissing -Path $script:localStagingFolder -Stage "PLAN"
    New-DirectoryIfMissing -Path $versionFolder -Stage "PLAN"

    ############################################################################################################
    # CREATE TEMPORARY MANAGED DISK
    ############################################################################################################

    Write-Log "Creating temporary managed disk from Azure Compute Gallery image version..." "DISK"

    $tempDiskNameRaw = "sync-$safeDefinitionName-$safeVersionName-$runId"
    $script:tempDiskName = New-SafeName -Name $tempDiskNameRaw -MaxLength 80

    Write-Log "Temporary disk name: $($script:tempDiskName)" "DISK"

    $galleryImageReference = @{
        Id = $script:latestVersion.Id
    }

    $diskConfig = New-AzDiskConfig `
        -Location $ExportLocation `
        -CreateOption FromImage `
        -GalleryImageReference $galleryImageReference `
        -SkuName $TempDiskSkuName `
        -ErrorAction Stop

    $managedDisk = New-AzDisk `
        -ResourceGroupName $TempDiskResourceGroupName `
        -DiskName $script:tempDiskName `
        -Disk $diskConfig `
        -ErrorAction Stop

    $script:tempDiskCreated = $true

    Write-Log "Temporary managed disk created." "DISK"
    Write-Log "Managed disk ID: $($managedDisk.Id)" "DISK"
    Write-Log "Managed disk size: $($managedDisk.DiskSizeGB) GiB" "DISK"

    ############################################################################################################
    # EXPORT DISK
    ############################################################################################################

    Write-Log "Generating disk export SAS URL..." "EXPORT"

    $diskSas = Grant-AzDiskAccess `
        -ResourceGroupName $TempDiskResourceGroupName `
        -DiskName $script:tempDiskName `
        -DurationInSecond $DiskSasDurationSeconds `
        -Access Read `
        -ErrorAction Stop

    $script:sasGranted = $true

    if (-not $diskSas.AccessSAS) {
        throw "Grant-AzDiskAccess returned no AccessSAS value."
    }

    Write-Log "Disk SAS generated successfully." "EXPORT"
    Write-Log "SAS duration seconds: $DiskSasDurationSeconds" "EXPORT"

    ############################################################################################################
    # DOWNLOAD
    ############################################################################################################

    $stagingVhdPath = Join-Path $script:localStagingFolder "$TemplatePrefix-$($script:latestVersion.Name).vhd"
    $stagingVhdxPath = Join-Path $script:localStagingFolder "$TemplatePrefix-$($script:latestVersion.Name).vhdx"

    $requiredDownloadBytes = [int64]$managedDisk.DiskSizeGB * 1GB

    if ($ConvertToVhdx -and $VhdxType -eq "Fixed") {
        $requiredDownloadBytes = $requiredDownloadBytes * 2
    }

    Test-FreeSpace `
        -Path $script:localStagingFolder `
        -RequiredBytes $requiredDownloadBytes

    Download-FileFromUri `
        -Uri $diskSas.AccessSAS `
        -DestinationPath $stagingVhdPath

    Validate-TemplateFile -Path $stagingVhdPath

    ############################################################################################################
    # CONVERT
    ############################################################################################################

    if ($ConvertToVhdx) {
        Write-Log "Converting VHD to VHDX..." "CONVERT"
        Write-Log "Source VHD: $stagingVhdPath" "CONVERT"
        Write-Log "Destination VHDX: $stagingVhdxPath" "CONVERT"
        Write-Log "VHDX type: $VhdxType" "CONVERT"

        Import-Module Hyper-V -ErrorAction Stop

        if (Test-Path $stagingVhdxPath) {
            Remove-Item -Path $stagingVhdxPath -Force -ErrorAction Stop
        }

        Convert-VHD `
            -Path $stagingVhdPath `
            -DestinationPath $stagingVhdxPath `
            -VHDType $VhdxType `
            -ErrorAction Stop

        Write-Log "Conversion completed successfully." "CONVERT"

        Validate-TemplateFile -Path $stagingVhdxPath

        if ($DeleteSourceVhdAfterConvert) {
            Remove-Item -Path $stagingVhdPath -Force -ErrorAction Stop
            Write-Log "Deleted source VHD after successful conversion." "CONVERT"
        }

        $stagedTemplatePath = $stagingVhdxPath
    }
    else {
        Write-Log "ConvertToVhdx is disabled. VHD will be promoted as the template." "CONVERT"
        $stagedTemplatePath = $stagingVhdPath
    }

    ############################################################################################################
    # PROMOTE TEMPLATE
    ############################################################################################################

    Write-Log "Promoting template to version repository..." "PROMOTE"

    if (Test-Path $versionedTemplatePath) {
        if ($OverwriteExistingVersion) {
            Write-Log "Existing versioned template found. OverwriteExistingVersion is true. Removing old file." "PROMOTE"
            Remove-Item -Path $versionedTemplatePath -Force -ErrorAction Stop
        }
        else {
            throw "Versioned template already exists: $versionedTemplatePath"
        }
    }

    Move-Item `
        -Path $stagedTemplatePath `
        -Destination $versionedTemplatePath `
        -Force `
        -ErrorAction Stop

    Write-Log "Template promoted successfully." "PROMOTE"
    Write-Log "Promoted template path: $versionedTemplatePath" "PROMOTE"

    Validate-TemplateFile -Path $versionedTemplatePath

    ############################################################################################################
    # UPDATE METADATA / AUTOMATION VARIABLES
    ############################################################################################################

    $metadata = [ordered]@{
        GalleryName                = $GalleryName
        GalleryResourceGroupName   = $GalleryResourceGroupName
        GalleryImageDefinitionName = $GalleryImageDefinitionName
        GalleryImageVersion        = $script:latestVersion.Name
        GalleryImageVersionId      = $script:latestVersion.Id
        TemplatePath               = $versionedTemplatePath
        TemplateRootPath           = $TemplateRootPath
        SyncedOn                   = (Get-Date).ToUniversalTime().ToString("o")
        SyncSource                 = "AzureComputeGallery"
        Runbook                    = "AVDHybridImageSync"
    }

    Write-CurrentMetadataFile -Metadata $metadata

    Set-AutomationVariableSafe -Name $CurrentGalleryVersionVariableName -Value $script:latestVersion.Name
    Set-AutomationVariableSafe -Name $CurrentTemplatePathVariableName -Value $versionedTemplatePath
    Set-AutomationVariableSafe -Name $LastSuccessfulSyncVariableName -Value (Get-Date).ToUniversalTime().ToString("o")
    Set-AutomationVariableSafe -Name $ImageSyncStatusVariableName -Value "Success-Synced | Version=$($script:latestVersion.Name)"
    Set-AutomationVariableSafe -Name $CurrentTemplateJsonVariableName -Value (($metadata | ConvertTo-Json -Depth 10 -Compress))

    $script:syncSucceeded = $true

    Write-Output "SUMMARY | Action=Synced | Version=$($script:latestVersion.Name) | TemplatePath=$versionedTemplatePath"
    Write-Log "Runbook complete"
}
catch {
    try {
        $failedVersion = "Unknown"

        if ($script:latestVersion -and $script:latestVersion.Name) {
            $failedVersion = $script:latestVersion.Name
        }

        Set-AutomationVariableSafe `
            -Name $ImageSyncStatusVariableName `
            -Value "Failed | Version=$failedVersion | Time=$((Get-Date).ToUniversalTime().ToString("o"))"
    }
    catch {
        Write-Log "Unable to update failed status variable: $($_.Exception.Message)" "ERROR"
    }

    Fail-Step "RUNBOOK" $_
    throw
}
finally {
    Invoke-Cleanup
}
