<# 
README
© Phoenix Software 2026
Developed by Aiden Wright

Purpose/Logic
- This runbook checks the latest Azure Compute Gallery image version.
- It compares that version against an Azure Automation Variable.
- If a newer image version exists:
    - Creates a temporary managed disk from the Azure Compute Gallery image version.
    - Grants temporary read access to the managed disk.
    - Downloads the exported VHD to a Hybrid Runbook Worker.
    - Converts the VHD to VHDX if configured.
    - Validates the template file.
    - Promotes the file into the local Hyper-V template repository.
    - Updates Azure Automation Variables so the deployment runbook knows the current version/template path.
- If no newer version exists, the runbook exits cleanly.

Required Azure Automation Variables
Create these as NON-ENCRYPTED variables before running:

AVDHybrid-CurrentGalleryVersion
AVDHybrid-CurrentTemplatePath
AVDHybrid-LastSuccessfulSync
AVDHybrid-ImageSyncStatus
AVDHybrid-CurrentTemplateJson

Recommended Managed Identity permissions
- Reader on the Azure Compute Gallery resource group.
- Contributor on the temporary managed disk resource group.
- Permission to read/update Automation Variables from the runbook.
- Hybrid Worker local/service account must have write access to the template repository path.

Required modules / worker requirements
- Az.Accounts
- Az.Compute
- Hyper-V PowerShell module on the Hybrid Runbook Worker if converting or validating VHD/VHDX.
- BitsTransfer module recommended for download.
#>

################################################################################################################
# CONFIGURATION
################################################################################################################

# Azure
$SubscriptionId                 = ""
$GalleryResourceGroupName       = "rg-avd-images-uks"
$GalleryName                    = "galavdprod001"
$GalleryImageDefinitionName     = "win11-enterprise-avd-hybrid"
$ExportLocation                 = "uksouth"

# Temporary managed disk
# Leave blank to use the gallery resource group.
$TempDiskResourceGroupName      = ""
$TempDiskSkuName                = "Standard_LRS"
$DiskSasDurationSeconds         = 43200 # 12 hours

# Local Hyper-V template repository
# This should be local to the Hybrid Worker or a UNC path the Hybrid Worker identity can write to.
$TemplateRootPath               = "D:\AVDHybridTemplates"
$TemplatePrefix                 = "avd-hybrid-win11-enterprise"

# Template handling
$ConvertToVhdx                  = $true
$VhdxType                       = "Dynamic" # Dynamic or Fixed
$ValidateWithHyperVModule       = $true
$MinimumTemplateSizeGiB         = 5

# Version handling
$RespectExcludeFromLatest       = $true
$ForceSync                      = $false
$OverwriteExistingVersion       = $false

# Safety / behaviour
$DeleteSourceVhdAfterConvert    = $true
$KeepFailedStaging              = $true
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
# FUNCTIONS
################################################################################################################

function Write-Log {
    param(
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
        [string]$Step,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-Log "================ ERROR BEGIN ================"
    Write-Log "FAILED at [$Step]"

    if ($null -ne $ErrorRecord) {
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
    }

    Write-Log "================ ERROR END =================="

    throw $ErrorRecord
}

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
        Write-Log "Automation Variable '$Name' could not be read. Returning empty value."
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
        Write-Log "WhatIfMode enabled. Would update Automation Variable '$Name' to '$Value'."
        return
    }

    Set-AutomationVariable -Name $Name -Value $Value -ErrorAction Stop
    Write-Log "Updated Automation Variable '$Name'."
}

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

function New-TemplateDirectories {
    $paths = @(
        $TemplateRootPath,
        (Join-Path $TemplateRootPath "_staging"),
        (Join-Path $TemplateRootPath "Versions"),
        (Join-Path $TemplateRootPath "Current")
    )

    foreach ($path in $paths) {
        if (-not (Test-Path $path)) {
            if ($WhatIfMode) {
                Write-Log "WhatIfMode enabled. Would create directory: $path" "INIT"
            }
            else {
                New-Item -Path $path -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Write-Log "Created directory: $path" "INIT"
            }
        }
    }
}

function Download-FileFromUri {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    if (Test-Path $DestinationPath) {
        Remove-Item -Path $DestinationPath -Force -ErrorAction Stop
    }

    Write-Log "Downloading VHD to: $DestinationPath" "DOWNLOAD"

    try {
        Import-Module BitsTransfer -ErrorAction Stop

        Start-BitsTransfer `
            -Source $Uri `
            -Destination $DestinationPath `
            -DisplayName "AVD Hybrid Image Sync" `
            -Description "Downloading exported Azure managed disk VHD" `
            -ErrorAction Stop

        Write-Log "Download completed using BITS." "DOWNLOAD"
    }
    catch {
        Write-Log "BITS download failed. Falling back to Invoke-WebRequest." "DOWNLOAD"
        Write-Log "BITS failure: $($_.Exception.Message)" "DOWNLOAD"

        Invoke-WebRequest `
            -Uri $Uri `
            -OutFile $DestinationPath `
            -UseBasicParsing `
            -ErrorAction Stop

        Write-Log "Download completed using Invoke-WebRequest." "DOWNLOAD"
    }
}

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
# MAIN
################################################################################################################

$ErrorActionPreference = "Stop"

$latestVersion = $null
$tempDiskName = $null
$tempDiskCreated = $false
$sasGranted = $false
$syncSucceeded = $false
$stagingFolder = $null

try {
    Write-Log "Runbook starting"
    Write-Log "This runbook must run on a Hybrid Runbook Worker with access to the local template repository."
    Write-Log "WhatIf mode: $WhatIfMode"

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
}
catch {
    Fail-Step "AUTH / INITIAL VALIDATION" $_
}

try {
    Write-Log "Initialising template repository..." "INIT"
    New-TemplateDirectories

    Write-Log "Gallery resource group: $GalleryResourceGroupName" "INIT"
    Write-Log "Gallery name: $GalleryName" "INIT"
    Write-Log "Gallery image definition: $GalleryImageDefinitionName" "INIT"
    Write-Log "Export location: $ExportLocation" "INIT"
    Write-Log "Temporary disk resource group: $TempDiskResourceGroupName" "INIT"
    Write-Log "Template root path: $TemplateRootPath" "INIT"
    Write-Log "Convert to VHDX: $ConvertToVhdx" "INIT"
    Write-Log "VHDX type: $VhdxType" "INIT"
}
catch {
    Fail-Step "INITIALISE" $_
}

try {
    $latestVersion = Get-LatestGalleryImageVersion
    $latestVersionName = [string]$latestVersion.Name

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
}
catch {
    Fail-Step "CHECK LATEST IMAGE VERSION" $_
}

try {
    $runId = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeDefinitionName = New-SafeName -Name $GalleryImageDefinitionName -MaxLength 40
    $safeVersionName = New-SafeName -Name $latestVersion.Name -MaxLength 20

    $stagingRoot = Join-Path $TemplateRootPath "_staging"
    $versionsRoot = Join-Path $TemplateRootPath "Versions"
    $versionFolder = Join-Path $versionsRoot $latestVersion.Name

    $stagingFolder = Join-Path $stagingRoot "$safeDefinitionName-$safeVersionName-$runId"

    $finalExtension = if ($ConvertToVhdx) { "vhdx" } else { "vhd" }
    $versionedTemplateName = "$TemplatePrefix-$($latestVersion.Name).$finalExtension"
    $versionedTemplatePath = Join-Path $versionFolder $versionedTemplateName

    Write-Log "Version folder: $versionFolder" "PLAN"
    Write-Log "Versioned template path: $versionedTemplatePath" "PLAN"

    if ((Test-Path $versionedTemplatePath) -and (-not $OverwriteExistingVersion)) {
        Write-Log "Template for version $($latestVersion.Name) already exists and OverwriteExistingVersion is false." "PLAN"
        Write-Log "Validating existing template and updating Automation Variables." "PLAN"

        Validate-TemplateFile -Path $versionedTemplatePath

        $metadata = [ordered]@{
            GalleryName                = $GalleryName
            GalleryResourceGroupName   = $GalleryResourceGroupName
            GalleryImageDefinitionName = $GalleryImageDefinitionName
            GalleryImageVersion        = $latestVersion.Name
            GalleryImageVersionId      = $latestVersion.Id
            TemplatePath               = $versionedTemplatePath
            TemplateRootPath           = $TemplateRootPath
            SyncedOn                   = (Get-Date).ToUniversalTime().ToString("o")
            SyncSource                 = "ExistingLocalTemplate"
            Runbook                    = "Sync-HybridAVDImage"
        }

        Write-CurrentMetadataFile -Metadata $metadata

        Set-AutomationVariableSafe -Name $CurrentGalleryVersionVariableName -Value $latestVersion.Name
        Set-AutomationVariableSafe -Name $CurrentTemplatePathVariableName -Value $versionedTemplatePath
        Set-AutomationVariableSafe -Name $LastSuccessfulSyncVariableName -Value (Get-Date).ToUniversalTime().ToString("o")
        Set-AutomationVariableSafe -Name $ImageSyncStatusVariableName -Value "Success-ExistingTemplate | Version=$($latestVersion.Name)"
        Set-AutomationVariableSafe -Name $CurrentTemplateJsonVariableName -Value (($metadata | ConvertTo-Json -Depth 10 -Compress))

        Write-Output "SUMMARY | Action=ExistingTemplatePromoted | Version=$($latestVersion.Name) | TemplatePath=$versionedTemplatePath"
        Write-Log "Runbook complete"
        return
    }

    if ($WhatIfMode) {
        Write-Log "WhatIfMode enabled. Sync plan only. No Azure disk, download, conversion, or variable update will be performed." "PLAN"
        Write-Log "Would create temporary managed disk from image version: $($latestVersion.Id)" "PLAN"
        Write-Log "Would download to staging folder: $stagingFolder" "PLAN"
        Write-Log "Would promote to: $versionedTemplatePath" "PLAN"
        Write-Output "SUMMARY | Action=WhatIf | Version=$($latestVersion.Name) | PlannedTemplatePath=$versionedTemplatePath"
        Write-Log "Runbook complete"
        return
    }

    if (-not (Test-Path $stagingFolder)) {
        New-Item -Path $stagingFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    if (-not (Test-Path $versionFolder)) {
        New-Item -Path $versionFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
}
catch {
    Fail-Step "PLAN SYNC" $_
}

try {
    Write-Log "Creating temporary managed disk from Azure Compute Gallery image version..." "DISK"

    $tempDiskNameRaw = "sync-$safeDefinitionName-$safeVersionName-$runId"
    $tempDiskName = New-SafeName -Name $tempDiskNameRaw -MaxLength 80

    Write-Log "Temporary disk name: $tempDiskName" "DISK"

    $galleryImageReference = @{
        Id = $latestVersion.Id
    }

    $diskConfig = New-AzDiskConfig `
        -Location $ExportLocation `
        -CreateOption FromImage `
        -GalleryImageReference $galleryImageReference `
        -SkuName $TempDiskSkuName `
        -ErrorAction Stop

    $managedDisk = New-AzDisk `
        -ResourceGroupName $TempDiskResourceGroupName `
        -DiskName $tempDiskName `
        -Disk $diskConfig `
        -ErrorAction Stop

    $tempDiskCreated = $true

    Write-Log "Temporary managed disk created." "DISK"
    Write-Log "Managed disk ID: $($managedDisk.Id)" "DISK"
    Write-Log "Managed disk size: $($managedDisk.DiskSizeGB) GiB" "DISK"
}
catch {
    Fail-Step "CREATE MANAGED DISK" $_
}

try {
    Write-Log "Generating disk export SAS URL..." "EXPORT"

    $diskSas = Grant-AzDiskAccess `
        -ResourceGroupName $TempDiskResourceGroupName `
        -DiskName $tempDiskName `
        -DurationInSecond $DiskSasDurationSeconds `
        -Access Read `
        -ErrorAction Stop

    $sasGranted = $true

    if (-not $diskSas.AccessSAS) {
        throw "Grant-AzDiskAccess returned no AccessSAS value."
    }

    Write-Log "Disk SAS generated successfully." "EXPORT"
    Write-Log "SAS duration seconds: $DiskSasDurationSeconds" "EXPORT"
}
catch {
    Fail-Step "EXPORT VHD SAS" $_
}

try {
    $stagingVhdPath = Join-Path $stagingFolder "$TemplatePrefix-$($latestVersion.Name).vhd"
    $stagingVhdxPath = Join-Path $stagingFolder "$TemplatePrefix-$($latestVersion.Name).vhdx"

    Download-FileFromUri -Uri $diskSas.AccessSAS -DestinationPath $stagingVhdPath

    Validate-TemplateFile -Path $stagingVhdPath
}
catch {
    Fail-Step "DOWNLOAD VHD" $_
}

try {
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
}
catch {
    Fail-Step "CONVERT / VALIDATE TEMPLATE" $_
}

try {
    Write-Log "Promoting template to version repository..." "PROMOTE"

    if (Test-Path $versionedTemplatePath) {
        if ($OverwriteExistingVersion) {
            Write-Log "Existing versioned template found. OverwriteExistingVersion is true, removing old file." "PROMOTE"
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

    $metadata = [ordered]@{
        GalleryName                = $GalleryName
        GalleryResourceGroupName   = $GalleryResourceGroupName
        GalleryImageDefinitionName = $GalleryImageDefinitionName
        GalleryImageVersion        = $latestVersion.Name
        GalleryImageVersionId      = $latestVersion.Id
        TemplatePath               = $versionedTemplatePath
        TemplateRootPath           = $TemplateRootPath
        SyncedOn                   = (Get-Date).ToUniversalTime().ToString("o")
        SyncSource                 = "AzureComputeGallery"
        Runbook                    = "Sync-HybridAVDImage"
    }

    Write-CurrentMetadataFile -Metadata $metadata

    Set-AutomationVariableSafe -Name $CurrentGalleryVersionVariableName -Value $latestVersion.Name
    Set-AutomationVariableSafe -Name $CurrentTemplatePathVariableName -Value $versionedTemplatePath
    Set-AutomationVariableSafe -Name $LastSuccessfulSyncVariableName -Value (Get-Date).ToUniversalTime().ToString("o")
    Set-AutomationVariableSafe -Name $ImageSyncStatusVariableName -Value "Success-Synced | Version=$($latestVersion.Name)"
    Set-AutomationVariableSafe -Name $CurrentTemplateJsonVariableName -Value (($metadata | ConvertTo-Json -Depth 10 -Compress))

    $syncSucceeded = $true

    Write-Output "SUMMARY | Action=Synced | Version=$($latestVersion.Name) | TemplatePath=$versionedTemplatePath"
}
catch {
    try {
        Set-AutomationVariableSafe -Name $ImageSyncStatusVariableName -Value "Failed | Version=$($latestVersion.Name) | Stage=PROMOTE | Time=$((Get-Date).ToUniversalTime().ToString("o"))"
    }
    catch {
        Write-Log "Unable to update failed status variable: $($_.Exception.Message)" "PROMOTE"
    }

    Fail-Step "PROMOTE TEMPLATE / UPDATE VARIABLES" $_
}
finally {
    Write-Log "Starting cleanup..." "CLEANUP"

    if ($sasGranted -and $tempDiskName) {
        try {
            Revoke-AzDiskAccess `
                -ResourceGroupName $TempDiskResourceGroupName `
                -DiskName $tempDiskName `
                -ErrorAction Stop | Out-Null

            Write-Log "Revoked temporary disk SAS access." "CLEANUP"
        }
        catch {
            Write-Log "Failed to revoke disk SAS access: $($_.Exception.Message)" "CLEANUP"
        }
    }

    if ($tempDiskCreated -and $tempDiskName) {
        try {
            Remove-AzDisk `
                -ResourceGroupName $TempDiskResourceGroupName `
                -DiskName $tempDiskName `
                -Force `
                -ErrorAction Stop | Out-Null

            Write-Log "Deleted temporary managed disk: $tempDiskName" "CLEANUP"
        }
        catch {
            Write-Log "Failed to delete temporary managed disk '$tempDiskName': $($_.Exception.Message)" "CLEANUP"
        }
    }

    if ($stagingFolder -and (Test-Path $stagingFolder)) {
        if ($syncSucceeded -or (-not $KeepFailedStaging)) {
            try {
                Remove-Item -Path $stagingFolder -Recurse -Force -ErrorAction Stop
                Write-Log "Removed staging folder: $stagingFolder" "CLEANUP"
            }
            catch {
                Write-Log "Failed to remove staging folder '$stagingFolder': $($_.Exception.Message)" "CLEANUP"
            }
        }
        else {
            Write-Log "Keeping staging folder for troubleshooting: $stagingFolder" "CLEANUP"
        }
    }

    Write-Log "Cleanup complete." "CLEANUP"
}

Write-Log "Runbook complete"
