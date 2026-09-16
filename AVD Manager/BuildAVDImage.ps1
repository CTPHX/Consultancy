<#
 © Phoenix Software 2026
 Developed by Aiden Wright

 AVD Manager image-build runbook.
 Clones a selected gold VM, syspreps a temporary clone and publishes the
 resulting OS disk to a selected Azure Compute Gallery image definition.

 All environment-specific values are supplied by AVD Manager.
#>

param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$Location,
    [Parameter(Mandatory = $true)][string]$GoldVmResourceGroupName,
    [Parameter(Mandatory = $true)][string]$GoldVmName,
    [Parameter(Mandatory = $true)][string]$GalleryResourceGroupName,
    [Parameter(Mandatory = $true)][string]$GalleryName,
    [Parameter(Mandatory = $true)][string]$GalleryImageDefinitionName,
    [Parameter(Mandatory = $true)][string]$GalleryImageVersion,
    [Parameter(Mandatory = $true)][string]$NetworkResourceGroupName,
    [Parameter(Mandatory = $true)][string]$VirtualNetworkName,
    [Parameter(Mandatory = $true)][string]$SubnetName,
    [Parameter(Mandatory = $false)][string]$VirtualMachineSize = "Standard_D2ds_v6",
    [Parameter(Mandatory = $false)][string]$TempResourceGroupPrefix = "avd-gold",
    [Parameter(Mandatory = $false)][ValidateRange(1,10)][int]$ReplicaCount = 1,
    [Parameter(Mandatory = $false)][string]$TargetRegionsCsv = "",
    [Parameter(Mandatory = $false)][bool]$ExcludeFromLatest = $false,
    [Parameter(Mandatory = $false)][ValidateRange(5,60)][int]$SysprepTimeoutMinutes = 15,
    [Parameter(Mandatory = $false)][ValidateRange(10,120)][int]$SysprepPollSeconds = 30
)

Import-Module Az.Accounts
Import-Module Az.Compute
Import-Module Az.Network
Import-Module Az.Resources

$TargetRegions = @(
    $TargetRegionsCsv.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($TargetRegions.Count -eq 0) { $TargetRegions = @($Location) }

################################################################################################################
# LOGGING
################################################################################################################
function Write-Log {
    param(
        [Parameter(Position = 0, Mandatory = $true)][string]$Message,
        [ValidateSet('INFO','SUCCESS','WARN','ERROR')][string]$Level = 'INFO',
        [string]$Component = 'IMAGE'
    )
    Write-Output ("[{0}] [{1}] [{2}] {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Component, $Message)
}

function Write-StepBanner {
    param([string]$Message)
    Write-Log -Level 'INFO' -Component 'STEP' -Message ("================ {0} ================" -f $Message)
}

function Fail-Step {
    param(
        [string]$Step,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $message = if ($null -ne $ErrorRecord) { $ErrorRecord.Exception.Message } else { "Unknown error" }
    Write-Log -Level 'ERROR' -Component $Step -Message $message

    if ($null -ne $ErrorRecord -and $ErrorRecord.InvocationInfo.Line) {
        Write-Log -Level 'ERROR' -Component $Step -Message ("Line: {0}" -f $ErrorRecord.InvocationInfo.Line.Trim())
    }
    if ($null -ne $ErrorRecord -and $ErrorRecord.ScriptStackTrace) {
        Write-Log -Level 'ERROR' -Component $Step -Message ("Stack: {0}" -f $ErrorRecord.ScriptStackTrace)
    }

    throw $ErrorRecord
}

function Get-NextGalleryVersion {
    param(
        [string]$ResourceGroupName,
        [string]$GalleryName,
        [string]$ImageDefinitionName
    )

    $versions = Get-AzGalleryImageVersion `
        -ResourceGroupName $ResourceGroupName `
        -GalleryName $GalleryName `
        -GalleryImageDefinitionName $ImageDefinitionName `
        -ErrorAction SilentlyContinue

    if (-not $versions) {
        return "0.0.1"
    }

    $latest = $versions | Sort-Object { [version]$_.Name } | Select-Object -Last 1
    $v = [version]$latest.Name

    $build = $v.Build + 1
    $minor = $v.Minor
    $major = $v.Major

    if ($build -ge 10) {
        $major++
        $build = 0
    }

    return "$major.$minor.$build"
}

function Wait-ForVmState {
    param(
        [string]$ResourceGroupName,
        [string]$VmName,
        [string[]]$States,
        [int]$MaxChecks = 45,
        [int]$SleepSeconds = 20
    )

    for ($i = 0; $i -lt $MaxChecks; $i++) {
        $status = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status -ErrorAction Stop
        $power = ($status.Statuses | Where-Object { $_.Code -like "PowerState/*" } | Select-Object -First 1).DisplayStatus

        Write-Log "VM state for '$VmName': $power"

        if ($States -contains $power) {
            return $true
        }

        Start-Sleep -Seconds $SleepSeconds
    }

    return $false
}

################################################################################################################
# AUTH
################################################################################################################
$ErrorActionPreference = "Stop"

try {
    Write-StepBanner -Message 'AUTHENTICATION'
    Write-Log -Component 'AUTH' -Message "Authenticating with managed identity..."
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Log -Level 'SUCCESS' -Component 'AUTH' -Message "Authenticated and subscription context set."
}
catch {
    Fail-Step "AUTH" $_
}

################################################################################################################
# VALIDATION
################################################################################################################
try {
    Write-StepBanner -Message 'VALIDATION'
    Write-Log -Component 'VALIDATION' -Message "Validating image-build inputs..."

    $goldVm = Get-AzVM -ResourceGroupName $GoldVmResourceGroupName -Name $GoldVmName -ErrorAction Stop
    Write-Log "Gold VM found: $GoldVmName"

    Get-AzGallery -ResourceGroupName $GalleryResourceGroupName -Name $GalleryName -ErrorAction Stop | Out-Null
    Write-Log "Gallery found: $GalleryName"

    Get-AzGalleryImageDefinition `
        -ResourceGroupName $GalleryResourceGroupName `
        -GalleryName $GalleryName `
        -Name $GalleryImageDefinitionName `
        -ErrorAction Stop | Out-Null

    Write-Log "Image definition found: $GalleryImageDefinitionName"
}
catch {
    Fail-Step "VALIDATION" $_
}

################################################################################################################
# VERSION
################################################################################################################
try {
    Write-StepBanner -Message 'VERSION'
    if ([string]::IsNullOrWhiteSpace($GalleryImageVersion) -or $GalleryImageVersion -eq 'Latest') {
        $versionNumber = Get-NextGalleryVersion `
            -ResourceGroupName $GalleryResourceGroupName `
            -GalleryName $GalleryName `
            -ImageDefinitionName $GalleryImageDefinitionName
    }
    else {
        try { [void][version]$GalleryImageVersion }
        catch { throw "Gallery image version '$GalleryImageVersion' is not a valid semantic version." }

        $existingVersion = Get-AzGalleryImageVersion `
            -ResourceGroupName $GalleryResourceGroupName `
            -GalleryName $GalleryName `
            -GalleryImageDefinitionName $GalleryImageDefinitionName `
            -Name $GalleryImageVersion `
            -ErrorAction SilentlyContinue

        if ($existingVersion) { throw "Gallery image version '$GalleryImageVersion' already exists." }
        $versionNumber = $GalleryImageVersion
    }

    Write-Log -Level 'SUCCESS' -Component 'VERSION' -Message "Version selected: $versionNumber"
}
catch {
    Fail-Step "VERSION" $_
}

################################################################################################################
# TEMP RESOURCE GROUP
################################################################################################################
$TempRG = "$TempResourceGroupPrefix-$(Get-Date -Format 'HHmmss')"

try {
    Write-Log "Creating temp resource group: $TempRG"
    New-AzResourceGroup -Name $TempRG -Location $Location -ErrorAction Stop | Out-Null
    Write-Log "Temp resource group created"
}
catch {
    Fail-Step "RESOURCE GROUP" $_
}

################################################################################################################
# SNAPSHOT + DISK
################################################################################################################
$tempVmName   = "$GoldVmName-vm-$versionNumber"
$snapshotName = "$GoldVmName-snap-$versionNumber"
$newDiskName  = "$GoldVmName-disk-$versionNumber"

try {
    Write-Log "Creating snapshot and cloned disk..."

    $diskName = $goldVm.StorageProfile.OsDisk.Name
    Write-Log "Source OS disk: $diskName"

    $disk = Get-AzDisk -ResourceGroupName $GoldVmResourceGroupName -DiskName $diskName -ErrorAction Stop

    $snapshotConfig = New-AzSnapshotConfig `
        -SourceUri $disk.Id `
        -CreateOption Copy `
        -Location $Location

    $snapshot = New-AzSnapshot `
        -Snapshot $snapshotConfig `
        -SnapshotName $snapshotName `
        -ResourceGroupName $TempRG `
        -ErrorAction Stop

    Write-Log "Snapshot created: $snapshotName"

    $newDiskConfig = New-AzDiskConfig `
        -Location $Location `
        -SourceResourceId $snapshot.Id `
        -CreateOption Copy

    $newDisk = New-AzDisk `
        -Disk $newDiskConfig `
        -ResourceGroupName $TempRG `
        -DiskName $newDiskName `
        -ErrorAction Stop

    Write-Log "Cloned disk created: $newDiskName"
}
catch {
    Fail-Step "DISK CLONE" $_
}

################################################################################################################
# NETWORK
################################################################################################################
try {
    Write-Log "Getting subnet '$SubnetName' from VNet '$VirtualNetworkName'..."

    $subnet = Get-AzVirtualNetwork `
        -Name $VirtualNetworkName `
        -ResourceGroupName $NetworkResourceGroupName `
        -ErrorAction Stop |
        Get-AzVirtualNetworkSubnetConfig |
        Where-Object { $_.Name -eq $SubnetName }

    if (-not $subnet) {
        throw "Subnet '$SubnetName' not found in VNet '$VirtualNetworkName'."
    }

    Write-Log "Subnet found"
}
catch {
    Fail-Step "NETWORK" $_
}

################################################################################################################
# VM CREATE
################################################################################################################
try {
    Write-Log "Creating temp VM: $tempVmName"

    $vmConfig = New-AzVMConfig -VMName $tempVmName -VMSize $VirtualMachineSize
    $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $newDisk.Id -CreateOption Attach -Windows

    $nic = New-AzNetworkInterface `
        -Name "$tempVmName-nic" `
        -ResourceGroupName $TempRG `
        -Location $Location `
        -SubnetId $subnet.Id `
        -ErrorAction Stop

    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

    New-AzVM `
        -VM $vmConfig `
        -ResourceGroupName $TempRG `
        -Location $Location `
        -DisableBginfoExtension `
        -ErrorAction Stop | Out-Null

    Write-Log "Temp VM created successfully"
}
catch {
    Fail-Step "VM CREATE" $_
}

################################################################################################################
# PREP WAIT
################################################################################################################
try {
    Write-Log "Waiting 30 seconds before sysprep..."
    Start-Sleep -Seconds 30
}
catch {
    Fail-Step "PRE-SYSPREP WAIT" $_
}

################################################################################################################
# SYSPREP
################################################################################################################
try {
    $MaxChecks = [math]::Ceiling(($SysprepTimeoutMinutes * 60) / $SysprepPollSeconds)

    Write-Log "Starting sysprep on temp VM..."

    $startSysprepScript = @'
$sysprepExe = "C:\Windows\System32\Sysprep\Sysprep.exe"

if (-not (Test-Path $sysprepExe)) {
    throw "Sysprep executable not found at $sysprepExe"
}

Start-Process -FilePath $sysprepExe `
    -ArgumentList "/generalize /oobe /mode:vm /shutdown" `
    -WindowStyle Hidden

Write-Output "Sysprep process launched successfully."
'@

    $runCmd = Invoke-AzVMRunCommand `
        -ResourceGroupName $TempRG `
        -VMName $tempVmName `
        -CommandId "RunPowerShellScript" `
        -ScriptString $startSysprepScript `
        -ErrorAction Stop

    Write-Output "===== Sysprep Start Output ====="
    $runCmd.Value | ForEach-Object { Write-Output $_.Message }

    Write-Log "Polling VM state for up to $SysprepTimeoutMinutes minutes..."

    $sysprepCompleted = $false

    for ($i = 1; $i -le $MaxChecks; $i++) {
        Start-Sleep -Seconds $SysprepPollSeconds

        $vmStatus = Get-AzVM `
            -ResourceGroupName $TempRG `
            -Name $tempVmName `
            -Status `
            -ErrorAction Stop

        $powerState   = $vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" } | Select-Object -First 1
        $powerCode    = $powerState.Code
        $powerDisplay = $powerState.DisplayStatus

        Write-Log "Sysprep check $i/$MaxChecks - VM state: $powerDisplay ($powerCode)"

        if ($powerCode -in @("PowerState/stopped", "PowerState/deallocated")) {
            $sysprepCompleted = $true
            Write-Log "Sysprep completed and VM has shut down."
            break
        }
    }

    if (-not $sysprepCompleted) {
        Write-Log "Sysprep exceeded $SysprepTimeoutMinutes minutes. Collecting Panther logs before failing..."

        $collectLogsScript = @'
$errLog = "C:\Windows\System32\Sysprep\Panther\setuperr.log"
$actLog = "C:\Windows\System32\Sysprep\Panther\setupact.log"

Write-Output "===== Sysprep timeout diagnostics ====="
Write-Output "Timestamp: $(Get-Date -Format s)"

try {
    $proc = Get-Process -Name sysprep -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Output "Sysprep process still running. PID(s): $($proc.Id -join ', ')"
    }
    else {
        Write-Output "Sysprep process is not currently running."
    }
}
catch {
    Write-Output "Unable to query sysprep.exe process: $($_.Exception.Message)"
}

if (Test-Path $errLog) {
    Write-Output "===== setuperr.log ====="
    Get-Content $errLog -Tail 200
}
else {
    Write-Output "setuperr.log not found"
}

if (Test-Path $actLog) {
    Write-Output "===== setupact.log ====="
    Get-Content $actLog -Tail 200
}
else {
    Write-Output "setupact.log not found"
}
'@

        try {
            $logCmd = Invoke-AzVMRunCommand `
                -ResourceGroupName $TempRG `
                -VMName $tempVmName `
                -CommandId "RunPowerShellScript" `
                -ScriptString $collectLogsScript `
                -ErrorAction Stop

            Write-Output "===== Sysprep Timeout Diagnostics ====="
            $logCmd.Value | ForEach-Object { Write-Output $_.Message }
        }
        catch {
            Write-Warning "Failed to collect sysprep logs from temp VM: $($_.Exception.Message)"
        }

        throw "Sysprep did not complete within $SysprepTimeoutMinutes minutes. Panther logs were written above where available."
    }

    Write-Log "Sysprep completed successfully within timeout."
}
catch {
    Fail-Step "SYSPREP" $_
}

################################################################################################################
# SYSPREP STATUS
################################################################################################################
try {
    $vmStatus = Get-AzVM `
        -ResourceGroupName $TempRG `
        -Name $tempVmName `
        -Status `
        -ErrorAction Stop

    $powerCode = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" } | Select-Object -First 1).Code

    if ($powerCode -notin @("PowerState/stopped", "PowerState/deallocated")) {
        Write-Log "Reading Sysprep status from registry..."

        $stateScript = @'
Get-ItemProperty -Path "HKLM:\SYSTEM\Setup\Status\SysprepStatus" | Format-List *
'@

        $state = Invoke-AzVMRunCommand `
            -ResourceGroupName $TempRG `
            -VMName $tempVmName `
            -CommandId "RunPowerShellScript" `
            -ScriptString $stateScript `
            -ErrorAction Stop

        Write-Output "===== Sysprep Status ====="
        $state.Value | ForEach-Object { Write-Output $_.Message }
    }
    else {
        Write-Log "Skipping guest sysprep status check because VM is already stopped."
    }
}
catch {
    Fail-Step "SYSPREP STATUS" $_
}

################################################################################################################
# STOP / DEALLOCATE
################################################################################################################
try {
    Write-Log "Stopping VM after successful sysprep..."

    Stop-AzVM `
        -Name $tempVmName `
        -ResourceGroupName $TempRG `
        -Force `
        -ErrorAction Stop | Out-Null

    Write-Log "Waiting for VM to reach deallocated state..."
    $deallocated = $false

    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 15

        $vmStatus = Get-AzVM `
            -ResourceGroupName $TempRG `
            -Name $tempVmName `
            -Status `
            -ErrorAction Stop

        $powerCode    = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" } | Select-Object -First 1).Code
        $powerDisplay = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" } | Select-Object -First 1).DisplayStatus

        Write-Log "Current VM power state: $powerDisplay ($powerCode)"

        if ($powerCode -eq "PowerState/deallocated") {
            $deallocated = $true
            break
        }
    }

    if (-not $deallocated) {
        throw "VM '$tempVmName' did not reach PowerState/deallocated."
    }

    Write-Log "VM deallocated successfully"
}
catch {
    Fail-Step "STOP / DEALLOCATE" $_
}

################################################################################################################
# PUBLISH TO ACG FROM OS DISK
################################################################################################################
try {
    Write-Log "Publishing to Azure Compute Gallery from OS disk..."

    $targetRegionsParam = @()
    foreach ($region in $TargetRegions) {
        $targetRegionsParam += @{
            Name               = $region
            ReplicaCount       = $ReplicaCount
            StorageAccountType = "Standard_LRS"
        }
    }

    $sourceVm = Get-AzVM -ResourceGroupName $TempRG -Name $tempVmName -ErrorAction Stop
    $osDiskId = $sourceVm.StorageProfile.OsDisk.ManagedDisk.Id

    Write-Log "Using OS disk as source: $osDiskId"

    New-AzGalleryImageVersion `
        -ResourceGroupName $GalleryResourceGroupName `
        -GalleryName $GalleryName `
        -GalleryImageDefinitionName $GalleryImageDefinitionName `
        -Name $versionNumber `
        -Location $Location `
        -TargetRegion $targetRegionsParam `
        -SourceImageId ([string]$osDiskId) `
        -PublishingProfileExcludeFromLatest:$ExcludeFromLatest `
        -ErrorAction Stop | Out-Null

    Write-Log "ACG image version created successfully: $versionNumber"
}
catch {
    Fail-Step "ACG PUBLISH" $_
}

################################################################################################################
# CLEANUP
################################################################################################################
try {
    Write-Log "Cleaning up temp resource group: $TempRG"
    Remove-AzResourceGroup -Name $TempRG -Force -ErrorAction Stop | Out-Null
    Write-Log "Cleanup complete"
}
catch {
    Write-Error "Cleanup failed for temp resource group '$TempRG'"
    Write-Error "Message: $($_.Exception.Message)"
}

Write-StepBanner -Message 'COMPLETE'
Write-Log -Level 'SUCCESS' -Component 'IMAGE' -Message "Image build completed successfully. Published '$GalleryImageDefinitionName' version '$versionNumber'."
