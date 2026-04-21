################################################################################################################
# README 
# © Phoenix Software 2026
# Developed by Aiden Wright
################################################################################################################
# 1. Create Automation Account with managed Identiy
# 2. Create Custom Role that will be assigned to the AVD Subscription
# 2a. Roles to be Assigned;
# [
# "Microsoft.Resources/subscriptions/read",
# "Microsoft.Resources/subscriptions/resourceGroups/read",
# "Microsoft.Resources/subscriptions/resourceGroups/write",
# "Microsoft.Resources/subscriptions/resourceGroups/delete",
# "Microsoft.Resources/deployments/*",
# "Microsoft.Compute/virtualMachines/read",
# "Microsoft.Compute/virtualMachines/write",
# "Microsoft.Compute/virtualMachines/delete",
# "Microsoft.Compute/virtualMachines/start/action",
# "Microsoft.Compute/virtualMachines/powerOff/action",
# "Microsoft.Compute/virtualMachines/deallocate/action",
# "Microsoft.Compute/virtualMachines/runCommand/action",
# "Microsoft.Compute/disks/read",
# "Microsoft.Compute/disks/write",
# "Microsoft.Compute/disks/delete",
# "Microsoft.Compute/disks/beginGetAccess/action",
# "Microsoft.Compute/disks/endGetAccess/action",
# "Microsoft.Compute/snapshots/read",
# "Microsoft.Compute/snapshots/write",
# "Microsoft.Compute/snapshots/delete",
# "Microsoft.Compute/snapshots/beginGetAccess/action",
# "Microsoft.Compute/snapshots/endGetAccess/action",
# "Microsoft.Compute/galleries/read",
# "Microsoft.Compute/galleries/images/read",
# "Microsoft.Compute/galleries/images/versions/read",
# "Microsoft.Compute/galleries/images/versions/write",
# "Microsoft.Network/virtualNetworks/read",
# "Microsoft.Network/virtualNetworks/subnets/read",
# "Microsoft.Network/virtualNetworks/subnets/join/action",
# "Microsoft.Network/networkInterfaces/read",
# "Microsoft.Network/networkInterfaces/write",
# "Microsoft.Network/networkInterfaces/delete",
# "Microsoft.Network/networkInterfaces/join/action"
# ]
# 3. Assign role to managed identity.
# 4. Make sure Az.Accounts, Az.Compute, Az.Network, Az.Resources has been configured on the Automation Account.
################################################################################################################

################################################################################################################
# Parameters
################################################################################################################
param(
    [Parameter(Mandatory = $true)]
    [string]$GoldVmName,

    [Parameter(Mandatory = $true)]
    [string]$GalleryName,

    [Parameter(Mandatory = $true)]
    [string]$GalleryImageDefinitionName
)

################################################################################################################
# MODULES
################################################################################################################

Import-Module Az.Accounts
Import-Module Az.Compute
Import-Module Az.Network
Import-Module Az.Resources

################################################################################################################
# CONFIG
################################################################################################################

$SubscriptionId = "x-x-x-x"
$Location = "UK South"

$ImagesResourceGroupName  = "rg-"
$NetworkResourceGroupName = "rg-"
$GalleryResourceGroupName = "rg-"

$VirtualNetworkName = "vnet-"
$SubnetName         = "snet-"

$VirtualMachineSize = "Standard_D2s_v5"
$TempResourceGroupPrefix = "avd-gold"

$ReplicaCount = 1
$TargetRegions = @($Location)
$ExcludeFromLatest = $false

################################################################################################################
# LOGGING
################################################################################################################

function Write-Log {
    param([string]$Message)
    Write-Output ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message)
}

function Fail-Step {
    param(
        [string]$Step,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-Output "================ ERROR BEGIN ================"
    Write-Output "FAILED at [$Step]"

    if ($null -ne $ErrorRecord) {
        Write-Output "Message:"
        Write-Output ($ErrorRecord.Exception.Message)

        if ($ErrorRecord.Exception.InnerException) {
            Write-Output "InnerException:"
            Write-Output ($ErrorRecord.Exception.InnerException.Message)
        }

        Write-Output "Invocation line:"
        Write-Output ($ErrorRecord.InvocationInfo.Line)

        Write-Output "Full ErrorRecord:"
        ($ErrorRecord | Format-List * -Force | Out-String) | Write-Output

        if ($ErrorRecord.Exception) {
            Write-Output "Full Exception:"
            ($ErrorRecord.Exception | Format-List * -Force | Out-String) | Write-Output
        }

        if ($ErrorRecord.ScriptStackTrace) {
            Write-Output "Script stack trace:"
            Write-Output ($ErrorRecord.ScriptStackTrace)
        }
    }

    Write-Output "================ ERROR END =================="
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

    $latest = $versions |
        Sort-Object { [version]$_.Name } |
        Select-Object -Last 1

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
    Write-Log "Authenticating..."
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Log "Authenticated successfully"
}
catch {
    Fail-Step "AUTH" $_
}

################################################################################################################
# VALIDATION
################################################################################################################

try {
    Write-Log "Validating inputs..."

    $goldVm = Get-AzVM -ResourceGroupName $ImagesResourceGroupName -Name $GoldVmName -ErrorAction Stop
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
    Write-Log "Getting next gallery version..."

    $versionNumber = Get-NextGalleryVersion `
        -ResourceGroupName $GalleryResourceGroupName `
        -GalleryName $GalleryName `
        -ImageDefinitionName $GalleryImageDefinitionName

    Write-Log "Version selected: $versionNumber"
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

$tempVmName = "$GoldVmName-vm-$versionNumber"
$snapshotName = "$GoldVmName-snap-$versionNumber"
$newDiskName = "$GoldVmName-disk-$versionNumber"

try {
    Write-Log "Creating snapshot and cloned disk..."

    $diskName = $goldVm.StorageProfile.OsDisk.Name
    Write-Log "Source OS disk: $diskName"

    $disk = Get-AzDisk -ResourceGroupName $ImagesResourceGroupName -DiskName $diskName -ErrorAction Stop

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
    Write-Log "Running sysprep on temp VM..."

    $sysprepScript = @'
$sysprep = Start-Process -FilePath "C:\Windows\System32\Sysprep\Sysprep.exe" `
    -ArgumentList "/generalize /oobe /mode:vm /quit" `
    -Wait -PassThru

Write-Output "Sysprep exit code: $($sysprep.ExitCode)"

$errLog = "C:\Windows\System32\Sysprep\Panther\setuperr.log"
$actLog = "C:\Windows\System32\Sysprep\Panther\setupact.log"

if (Test-Path $errLog) {
    Write-Output "===== setuperr.log ====="
    Get-Content $errLog -Tail 100
}
else {
    Write-Output "setuperr.log not found"
}

if (Test-Path $actLog) {
    Write-Output "===== setupact.log ====="
    Get-Content $actLog -Tail 100
}
else {
    Write-Output "setupact.log not found"
}

if ($sysprep.ExitCode -ne 0) {
    throw "Sysprep failed with exit code $($sysprep.ExitCode)"
}
'@

    $runCmd = Invoke-AzVMRunCommand `
        -ResourceGroupName $TempRG `
        -VMName $tempVmName `
        -CommandId "RunPowerShellScript" `
        -ScriptString $sysprepScript `
        -ErrorAction Stop

    Write-Output "===== Run Command Output ====="
    $runCmd.Value | ForEach-Object {
        Write-Output $_.Message
    }

    Write-Log "Sysprep command finished"
}
catch {
    Fail-Step "SYSPREP" $_
}

################################################################################################################
# POST-SYSPREP WAIT
################################################################################################################

try {
    Write-Log "Waiting 30 seconds after sysprep..."
    Start-Sleep -Seconds 30
}
catch {
    Fail-Step "POST-SYSPREP WAIT" $_
}

################################################################################################################
# SYSPREP STATUS
################################################################################################################

try {
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
    $state.Value | ForEach-Object {
        Write-Output $_.Message
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

        $powerCode = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" } | Select-Object -First 1).Code
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
            Name = $region
            ReplicaCount = $ReplicaCount
            StorageAccountType = "Standard_LRS"
        }
    }

    $sourceVm = Get-AzVM -ResourceGroupName $TempRG -Name $tempVmName -ErrorAction Stop
    $osDiskId = $sourceVm.StorageProfile.OsDisk.ManagedDisk.Id

    Write-Log "Using OS disk as source: $osDiskId"

    $osDiskImage = @{
        Source = @{
            Id = $osDiskId
        }
    }

    New-AzGalleryImageVersion `
        -ResourceGroupName $GalleryResourceGroupName `
        -GalleryName $GalleryName `
        -GalleryImageDefinitionName $GalleryImageDefinitionName `
        -Name $versionNumber `
        -Location $Location `
        -TargetRegion $targetRegionsParam `
        -OSDiskImage $osDiskImage `
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

Write-Log "SUCCESS"
