<#
© Phoenix Software 2026
Developed by Aiden Wright

.SYNOPSIS
AVD production deployment runbook for Azure Automation.

.DESCRIPTION
Environment configuration is hardcoded at the top of the script for safety.
Only runtime controls remain in the param block.

RUNTIME PARAMETERS
- VmNamePrefix
- SessionHostCount
- OverwriteExisting

JOIN TYPES
- ADDS  = classic Active Directory / Entra Domain Services join using Key Vault credentials
- ENTRA = Microsoft Entra join using AADLoginForWindows extension, with Intune enrollment dependent on tenant-side MDM configuration

NOTES
- Replace the placeholder values in the ENVIRONMENT CONFIG section before use.
- Local admin credentials are read from Key Vault.
- ADDS join credentials are read from Key Vault when JoinType = ADDS.
- This runbook is intended for Azure Automation with a managed identity.

Managed Identity Requirements
- Virtual Machine Contributor
- Network Contributor
- Desktop Virtualization Host Pool Contributor
- Key Vault Secrets User
- Reader
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$VmNamePrefix,

    [Parameter(Mandatory = $true)]
    [int]$SessionHostCount,

    [Parameter(Mandatory = $false)]
    [bool]$OverwriteExisting = $false
)

# ==========================================
# ENVIRONMENT CONFIG - PROD
# Replace all placeholder values before use
# ==========================================

$SubscriptionId                    = ""
$Location                          = "uksouth"

# Deployment configuration
$JoinType                          = "ADDS"
$HostPoolName                      = "vdpool-avd-prod-uks-desktops01"
$GalleryImageDefinitionName        = "WINDOWS11-EMS-Pre"

$HostPoolResourceGroupName         = "rg-avd-hosts-uks"

$SessionHostResourceGroupName      = "rg-avd-hosts-uks"

$GalleryResourceGroupName          = "rg-avd-images-uks"
$GalleryName                       = "acgphxdzuks"

$VirtualNetworkResourceGroupName   = "rg-avd-network-uks"
$VirtualNetworkName                = "vnet-spoke-avd-uks"
$SubnetName                        = "snet-avd-internal-uks"

$VmSize                            = "Standard_D2ds_v6"

$KeyVaultName                      = "3"
$LocalAdminUsernameSecretName      = "adm-local-upn"
$LocalAdminPasswordSecretName      = "adm-local-pw"

# ADDS join settings
$DomainFqdn                        = ""
$DomainOuPath                      = ""
$DomainJoinUsernameSecretName      = "domainjoin-upn"
$DomainJoinPasswordSecretName      = "domainjoin-pw"

# ENTRA join settings
$TenantId                          = ""
$EnableIntuneEnrollment            = $True
$IntuneMdmId                       = "0000000a-0000-0000-c000-000000000000"

# Optional defaults
$DrainModeBeforeDelete             = $false
$ForceLogoffUsers                  = $false
$InstallRdsRoleOnServerOS          = $false
$RegistrationTokenHours            = 24
$VmCreationThrottleSeconds         = 10
$VmReadyTimeoutMinutes             = 25
$RegistrationTimeoutMinutes        = 25
$EntraJoinWaitTimeoutMinutes       = 15
$EntraJoinWaitPollSeconds          = 30
$RequireEntraDeviceAuthSuccess     = $true
$Tags                              = @{
    "Workload"    = "AVD"
    "Environment" = "Prod"
    "ManagedBy"   = "AzureAutomation"
}


$ErrorActionPreference = 'Stop'
$ConfirmPreference = 'None'

function Write-Log {
    param(
        [Parameter(Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')]
        [string]$Level = 'INFO',

        [Parameter(Position = 2)]
        [string]$Component = 'RUNBOOK'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output ("[{0}] [{1}] [{2}] {3}" -f $timestamp, $Level, $Component, $Message)
}

function Write-StepBanner {
    param([string]$Message)
    Write-Log -Level 'INFO' -Component 'STEP' -Message ("================ {0} ================" -f $Message)
}

function Throw-RunbookError {
    param(
        [string]$Step,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-Log -Level 'ERROR' -Component $Step -Message $ErrorRecord.Exception.Message
    if ($ErrorRecord.InvocationInfo.Line) {
        Write-Log -Level 'ERROR' -Component $Step -Message ("Line: {0}" -f $ErrorRecord.InvocationInfo.Line)
    }
    if ($ErrorRecord.ScriptStackTrace) {
        Write-Log -Level 'ERROR' -Component $Step -Message ("Stack: {0}" -f $ErrorRecord.ScriptStackTrace)
    }
    throw $ErrorRecord
}

function Connect-RunbookAz {
    try {
        Write-StepBanner -Message 'AUTHENTICATION'
        Write-Log -Level 'INFO' -Component 'AUTH' -Message "Authenticating with managed identity..."
        Disable-AzContextAutosave -Scope Process | Out-Null
        Connect-AzAccount -Identity | Out-Null
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        Write-Log -Level 'SUCCESS' -Component 'AUTH' -Message "Authenticated and subscription context set."
    }
    catch {
        Throw-RunbookError -Step "AUTHENTICATION" -ErrorRecord $_
    }
}

function Test-JoinConfiguration {
    Write-Log "Validating join configuration for JoinType '$JoinType'..."

    if ($JoinType -eq 'ADDS') {
        if ([string]::IsNullOrWhiteSpace($DomainFqdn)) {
            throw "JoinType ADDS requires DomainFqdn."
        }
        if ([string]::IsNullOrWhiteSpace($DomainJoinUsernameSecretName)) {
            throw "JoinType ADDS requires DomainJoinUsernameSecretName."
        }
        if ([string]::IsNullOrWhiteSpace($DomainJoinPasswordSecretName)) {
            throw "JoinType ADDS requires DomainJoinPasswordSecretName."
        }
    }

    if ($JoinType -eq 'ENTRA') {
        if ([string]::IsNullOrWhiteSpace($TenantId)) {
            Write-Log "TenantId not supplied. Proceeding, but explicit tenant-oriented validation is limited."
        }

        if ($EnableIntuneEnrollment -and [string]::IsNullOrWhiteSpace($IntuneMdmId)) {
            throw "EnableIntuneEnrollment is true, but IntuneMdmId is empty."
        }
    }
}

function Get-PlainSecretOrThrow {
    param(
        [string]$VaultName,
        [string]$SecretName
    )

    try {
        $value = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -AsPlainText
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Secret '$SecretName' was empty."
        }
        return $value
    }
    catch {
        Throw-RunbookError -Step "GET_KEYVAULT_SECRET_$SecretName" -ErrorRecord $_
    }
}

function Get-PSCredentialFromKeyVault {
    param(
        [string]$VaultName,
        [string]$UsernameSecretName,
        [string]$PasswordSecretName
    )

    $username = Get-PlainSecretOrThrow -VaultName $VaultName -SecretName $UsernameSecretName
    $password = Get-PlainSecretOrThrow -VaultName $VaultName -SecretName $PasswordSecretName
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    return [pscredential]::new($username, $securePassword)
}

function Get-SessionHostVmNameFromResourceId {
    param([string]$ResourceId)

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        return $null
    }

    $parts = $ResourceId.Trim('/') -split '/'
    $vmIndex = [Array]::IndexOf($parts, 'virtualMachines')
    if ($vmIndex -ge 0 -and $vmIndex + 1 -lt $parts.Length) {
        return $parts[$vmIndex + 1]
    }
    return $null
}

function Get-SessionHostShortName {
    param([string]$SessionHostName)

    if ([string]::IsNullOrWhiteSpace($SessionHostName)) {
        return $null
    }

    $leaf = ($SessionHostName -split '/')[-1]
    return ($leaf -split '\.')[0]
}

function Get-ExistingSessionHostVmNames {
    $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName -ErrorAction SilentlyContinue
    if (-not $sessionHosts) {
        return @()
    }

    $names = @()
    foreach ($sessionHost in $sessionHosts) {
        $shortVmName = Get-SessionHostShortName -SessionHostName $sessionHost.Name
        if ($shortVmName) {
            $names += $shortVmName
        }
    }

    return @($names | Sort-Object -Unique)
}

function Get-NextVmNamesForHostPoolCount {
    param(
        [string]$Prefix,
        [int]$Count,
        [int]$ExistingHostCount
    )

    $newNames = @()
    for ($i = 1; $i -le $Count; $i++) {
        $newNames += ('{0}-{1:D2}' -f $Prefix, ($ExistingHostCount + $i))
    }

    return $newNames
}

function Wait-ForVmPowerState {
    param(
        [string]$ResourceGroupName,
        [string]$VmName,
        [string[]]$DesiredStates,
        [int]$TimeoutMinutes = 20,
        [int]$PollSeconds = 20,
        [ref]$Succeeded
    )

    $Succeeded.Value = $false
    $maxChecks = [math]::Ceiling(($TimeoutMinutes * 60) / $PollSeconds)

    for ($i = 1; $i -le $maxChecks; $i++) {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status
        $powerState = ($vm.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1).DisplayStatus
        Write-Log "VM '$VmName' power state: $powerState"
        if ($DesiredStates -contains $powerState) {
            $Succeeded.Value = $true
            return
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Wait-ForSessionHostRegistration {
    param(
        [string]$ExpectedVmName,
        [int]$TimeoutMinutes = 20,
        [int]$PollSeconds = 30,
        [ref]$Registered
    )

    $Registered.Value = $false
    $maxChecks = [math]::Ceiling(($TimeoutMinutes * 60) / $PollSeconds)

    for ($i = 1; $i -le $maxChecks; $i++) {
        $hosts = Get-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName -ErrorAction SilentlyContinue
        $match = $hosts | Where-Object {
            $short = Get-SessionHostShortName -SessionHostName $_.Name
            $short -eq $ExpectedVmName
        }

        if ($match) {
            Write-Log "Session host '$ExpectedVmName' is now registered in host pool '$HostPoolName'."
            $Registered.Value = $true
            return
        }

        Write-Log "Waiting for session host '$ExpectedVmName' to register..."
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-LatestGalleryImageVersionId {
    param(
        [string]$ResourceGroupName,
        [string]$GalleryName,
        [string]$ImageDefinitionName
    )

    $versions = Get-AzGalleryImageVersion `
        -ResourceGroupName $ResourceGroupName `
        -GalleryName $GalleryName `
        -GalleryImageDefinitionName $ImageDefinitionName

    if (-not $versions) {
        throw "No image versions found for '$ImageDefinitionName' in gallery '$GalleryName'."
    }

    $latest = $versions | Sort-Object { [version]$_.Name } | Select-Object -Last 1
    return $latest.Id
}

function Get-HostPoolRegistrationToken {
    param(
        [ref]$RegistrationToken
    )

    $RegistrationToken.Value = $null
    $expiration = (Get-Date).ToUniversalTime().AddHours($RegistrationTokenHours).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')

    Write-StepBanner -Message 'REGISTRATION TOKEN'
    Write-Log -Level 'INFO' -Component 'AVD' -Message "Generating AVD registration token valid for $RegistrationTokenHours hour(s)..."
    $token = New-AzWvdRegistrationInfo `
        -ResourceGroupName $HostPoolResourceGroupName `
        -HostPoolName $HostPoolName `
        -ExpirationTime $expiration

    if (-not $token.Token) {
        throw "Host pool registration token was not returned."
    }

    $RegistrationToken.Value = $token.Token
}

function ConvertTo-SingleQuotedLiteral {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return "''"
    }

    return "'" + ($Value -replace "'", "''") + "'"
}

function Remove-AdComputerObjectIfRequired {
    param(
        [string]$VmName,
        [pscredential]$DomainJoinCredential
    )

    if ($JoinType -ne 'ADDS') {
        return
    }

    if (-not $OverwriteExisting) {
        return
    }

    if (-not $DomainJoinCredential) {
        Write-Log -Level 'WARN' -Component 'ADDS' -Message "No AD DS credential was available. Skipping AD computer object cleanup for '$VmName'."
        return
    }

    Write-Log -Level 'INFO' -Component 'ADDS' -Message "Attempting to remove AD computer object for '$VmName' before deleting the VM..."

    $plainPassword = $null
    $bstr = [IntPtr]::Zero

    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($DomainJoinCredential.Password)
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

        $domainDn = (($DomainFqdn -split '\.') | ForEach-Object { "DC=$_" }) -join ','
        $userLiteral = ConvertTo-SingleQuotedLiteral -Value $DomainJoinCredential.UserName
        $passwordLiteral = ConvertTo-SingleQuotedLiteral -Value $plainPassword
        $domainDnLiteral = ConvertTo-SingleQuotedLiteral -Value $domainDn
        $vmNameLiteral = ConvertTo-SingleQuotedLiteral -Value $VmName

        $cleanupScript = @"
`$ErrorActionPreference = 'Stop'

`$username = $userLiteral
`$password = $passwordLiteral
`$domainDn = $domainDnLiteral
`$vmName = $vmNameLiteral

try {
    Add-Type -AssemblyName System.DirectoryServices

    `$root = New-Object System.DirectoryServices.DirectoryEntry("LDAP://`$domainDn", `$username, `$password)
    `$searcher = New-Object System.DirectoryServices.DirectorySearcher(`$root)
    `$searcher.Filter = "(&(objectCategory=computer)(sAMAccountName=`$vmName`$))"
    `$searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree

    `$result = `$searcher.FindOne()

    if (`$null -eq `$result) {
        Write-Output "No AD computer object found for '`$vmName'."
        return
    }

    `$computerObject = `$result.GetDirectoryEntry()
    `$distinguishedName = `$computerObject.Properties['distinguishedName'][0]
    `$computerObject.DeleteTree()
    `$computerObject.CommitChanges()

    Write-Output "Removed AD computer object '`$distinguishedName'."
}
catch {
    Write-Output "AD computer object cleanup failed for '`$vmName': `$(`$_.Exception.Message)"
    throw
}
"@

        $cleanupResult = Invoke-AzVMRunCommand `
            -ResourceGroupName $SessionHostResourceGroupName `
            -VMName $VmName `
            -CommandId 'RunPowerShellScript' `
            -ScriptString $cleanupScript `
            -ErrorAction Stop

        $cleanupResult.Value | ForEach-Object {
            if ($_.Message) {
                Write-Log -Level 'INFO' -Component 'ADDS' -Message $_.Message
            }
        }
    }
    catch {
        Write-Log -Level 'WARN' -Component 'ADDS' -Message ("Could not remove AD computer object for '{0}'. The VM deletion will continue. Error: {1}" -f $VmName, $_.Exception.Message)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        $plainPassword = $null
    }
}


function Invoke-DrainAndDeleteExistingHosts {
    param(
        [pscredential]$DomainJoinCredential
    )

    Write-Log "Enumerating existing session hosts in host pool '$HostPoolName'..."
    $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName -ErrorAction SilentlyContinue

    if (-not $sessionHosts) {
        Write-Log "No existing session hosts found."
        return
    }

    foreach ($sessionHost in $sessionHosts) {
        $sessionHostFullName = $sessionHost.Name
        $sessionHostName = ($sessionHostFullName -split '/')[-1]
        $shortVmName = Get-SessionHostShortName -SessionHostName $sessionHostName
        $vmName = Get-SessionHostVmNameFromResourceId -ResourceId $sessionHost.ResourceId
        if (-not $vmName) { $vmName = $shortVmName }

        Write-Log "Processing existing session host '$sessionHostFullName' as '$sessionHostName' (VM: '$vmName')..."

        try {
            if ($DrainModeBeforeDelete) {
                Write-Log "Enabling drain mode for '$sessionHostName'..."
                Update-AzWvdSessionHost `
                    -ResourceGroupName $HostPoolResourceGroupName `
                    -HostPoolName $HostPoolName `
                    -Name $sessionHostName `
                    -AllowNewSession:$false | Out-Null
            }

            if ($ForceLogoffUsers) {
                $userSessions = Get-AzWvdUserSession `
                    -ResourceGroupName $HostPoolResourceGroupName `
                    -HostPoolName $HostPoolName `
                    -SessionHostName $sessionHostName `
                    -ErrorAction SilentlyContinue

                foreach ($userSession in $userSessions) {
                    Write-Log "Logging off session id '$($userSession.Id)' from '$sessionHostName'..."
                    Remove-AzWvdUserSession `
                        -ResourceGroupName $HostPoolResourceGroupName `
                        -HostPoolName $HostPoolName `
                        -SessionHostName $sessionHostName `
                        -Id $userSession.Id `
                        -Force `
                        -Confirm:$false | Out-Null
                }
            }

            Write-Log "Removing AVD session host object '$sessionHostName'..."
            Remove-AzWvdSessionHost `
                -ResourceGroupName $HostPoolResourceGroupName `
                -HostPoolName $HostPoolName `
                -Name $sessionHostName `
                -Force `
                -Confirm:$false | Out-Null
        }
        catch {
            Throw-RunbookError -Step "REMOVE_SESSION_HOST_$sessionHostName" -ErrorRecord $_
        }

        Remove-AdComputerObjectIfRequired -VmName $vmName -DomainJoinCredential $DomainJoinCredential

        try {
            $vm = Get-AzVM -ResourceGroupName $SessionHostResourceGroupName -Name $vmName -ErrorAction SilentlyContinue

            if (-not $vm) {
                Write-Log "VM '$vmName' was not found in resource group '$SessionHostResourceGroupName'. Skipping VM resource deletion."
                continue
            }

            $nicIds = @($vm.NetworkProfile.NetworkInterfaces.Id)
            $osDiskName = $vm.StorageProfile.OsDisk.Name
            $dataDiskNames = @($vm.StorageProfile.DataDisks | ForEach-Object { $_.Name })

            Write-Log "Deleting VM '$vmName'..."
            Remove-AzVM -ResourceGroupName $SessionHostResourceGroupName -Name $vmName -Force

            foreach ($nicId in $nicIds) {
                $nicName = ($nicId -split '/')[-1]
                Write-Log "Deleting NIC '$nicName'..."
                Remove-AzNetworkInterface -ResourceGroupName $SessionHostResourceGroupName -Name $nicName -Force -ErrorAction SilentlyContinue
            }

            if ($osDiskName) {
                Write-Log "Deleting OS disk '$osDiskName'..."
                Remove-AzDisk -ResourceGroupName $SessionHostResourceGroupName -DiskName $osDiskName -Force -ErrorAction SilentlyContinue
            }

            foreach ($diskName in $dataDiskNames) {
                Write-Log "Deleting data disk '$diskName'..."
                Remove-AzDisk -ResourceGroupName $SessionHostResourceGroupName -DiskName $diskName -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Throw-RunbookError -Step "DELETE_VM_RESOURCES_$vmName" -ErrorRecord $_
        }
    }
}

function New-SessionHostVm {
    param(
        [string]$VmName,
        [string]$ImageVersionId,
        [pscredential]$LocalAdminCredential
    )

    $subnet = Get-AzVirtualNetwork `
        -Name $VirtualNetworkName `
        -ResourceGroupName $VirtualNetworkResourceGroupName | `
        Get-AzVirtualNetworkSubnetConfig | `
        Where-Object { $_.Name -eq $SubnetName }

    if (-not $subnet) {
        throw "Subnet '$SubnetName' not found in VNet '$VirtualNetworkName'."
    }

    $nicName = "$VmName-nic"

    $existingVm = Get-AzVM -ResourceGroupName $SessionHostResourceGroupName -Name $VmName -ErrorAction SilentlyContinue
    if ($existingVm) {
        throw "VM '$VmName' already exists in resource group '$SessionHostResourceGroupName'. This is likely from a previous failed run. Delete the existing VM/resources or rerun with a new VmNamePrefix."
    }

    $existingNic = Get-AzNetworkInterface -ResourceGroupName $SessionHostResourceGroupName -Name $nicName -ErrorAction SilentlyContinue
    if ($existingNic) {
        Write-Log -Level 'WARN' -Component 'NETWORK' -Message "NIC '$nicName' already exists. Removing stale NIC before recreating it."
        Remove-AzNetworkInterface -ResourceGroupName $SessionHostResourceGroupName -Name $nicName -Force -Confirm:$false
    }

    Write-Log "Creating NIC '$nicName'..."
    $nic = New-AzNetworkInterface `
        -Name $nicName `
        -ResourceGroupName $SessionHostResourceGroupName `
        -Location $Location `
        -SubnetId $subnet.Id `
        -Force

    Write-Log "Building VM config for '$VmName'..."
    $vmConfig = New-AzVMConfig `
        -VMName $VmName `
        -VMSize $VmSize `
        -IdentityType SystemAssigned
    $vmConfig = Set-AzVMOperatingSystem `
        -VM $vmConfig `
        -Windows `
        -ComputerName $VmName `
        -Credential $LocalAdminCredential `
        -ProvisionVMAgent `
        -EnableAutoUpdate
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id
    $vmConfig = Set-AzVMSourceImage -VM $vmConfig -Id $ImageVersionId

    Write-Log "Creating VM '$VmName' from gallery image..."
    New-AzVM `
        -ResourceGroupName $SessionHostResourceGroupName `
        -Location $Location `
        -VM $vmConfig `
        -Tag $Tags | Out-Null

    $isReady = $false
    Wait-ForVmPowerState `
        -ResourceGroupName $SessionHostResourceGroupName `
        -VmName $VmName `
        -DesiredStates @('VM running') `
        -TimeoutMinutes $VmReadyTimeoutMinutes `
        -Succeeded ([ref]$isReady)

    if (-not $isReady) {
        throw "VM '$VmName' did not reach the running state within the timeout."
    }
}

function Join-SessionHostAdDs {
    param(
        [string]$VmName,
        [pscredential]$DomainJoinCredential
    )

    Write-Log "Applying AD DS join extension to '$VmName' for domain '$DomainFqdn'..."

    # This wraps the JsonADDomainExtension path used by Set-AzVMADDomainExtension.
    Set-AzVMADDomainExtension `
        -ResourceGroupName $SessionHostResourceGroupName `
        -VMName $VmName `
        -Name 'joindomain' `
        -DomainName $DomainFqdn `
        -Credential $DomainJoinCredential `
        -OUPath $DomainOuPath `
        -JoinOption 3 `
        -Restart `
        -ForceRerun (Get-Date).Ticks | Out-Null

    $isReady = $false
    Wait-ForVmPowerState `
        -ResourceGroupName $SessionHostResourceGroupName `
        -VmName $VmName `
        -DesiredStates @('VM running') `
        -TimeoutMinutes $VmReadyTimeoutMinutes `
        -Succeeded ([ref]$isReady)

    if (-not $isReady) {
        throw "VM '$VmName' did not return to running after AD DS join."
    }
}

function Join-SessionHostEntra {
    param(
        [string]$VmName
    )

    Write-Log "Enabling Microsoft Entra sign-in extension on '$VmName'..."

    if ($EnableIntuneEnrollment) {
        Write-Log -Level 'INFO' -Component 'ENTRA' -Message ("Intune enrollment is enabled for Entra join. AADLoginForWindows mdmId will be set to '{0}'." -f $IntuneMdmId)

        $aadLoginSettings = @{
            mdmId = $IntuneMdmId
        }

        Set-AzVMExtension `
            -ResourceGroupName $SessionHostResourceGroupName `
            -VMName $VmName `
            -Location $Location `
            -Publisher 'Microsoft.Azure.ActiveDirectory' `
            -ExtensionType 'AADLoginForWindows' `
            -Name 'AADLoginForWindows' `
            -TypeHandlerVersion '2.2' `
            -SettingString ($aadLoginSettings | ConvertTo-Json -Compress) `
            -EnableAutomaticUpgrade $false | Out-Null
    }
    else {
        Write-Log -Level 'INFO' -Component 'ENTRA' -Message "Intune enrollment is disabled for Entra join. AADLoginForWindows will be applied without extension settings."

        Set-AzVMExtension `
            -ResourceGroupName $SessionHostResourceGroupName `
            -VMName $VmName `
            -Location $Location `
            -Publisher 'Microsoft.Azure.ActiveDirectory' `
            -ExtensionType 'AADLoginForWindows' `
            -Name 'AADLoginForWindows' `
            -TypeHandlerVersion '2.2' `
            -EnableAutomaticUpgrade $false | Out-Null
    }

    Write-Log "Microsoft Entra sign-in extension applied to '$VmName'."

    if ($EnableIntuneEnrollment) {
        Write-Log "EnableIntuneEnrollment is set. The AADLoginForWindows extension was applied with the Intune mdmId setting."
        Write-Log "Tenant-side MDM auto-enrollment configuration and licensing must still be valid for Intune enrollment to complete."
    }

    $entraJoined = $false
    Wait-ForEntraJoinCompletion `
        -VmName $VmName `
        -TimeoutMinutes $EntraJoinWaitTimeoutMinutes `
        -PollSeconds $EntraJoinWaitPollSeconds `
        -RequireDeviceAuthSuccess $RequireEntraDeviceAuthSuccess `
        -Joined ([ref]$entraJoined)

    if (-not $entraJoined) {
        throw "VM '$VmName' did not complete Microsoft Entra join within the timeout. AVD agent installation has been stopped so the host does not register before Entra join is healthy."
    }
}


function Wait-ForEntraJoinCompletion {
    param(
        [string]$VmName,
        [int]$TimeoutMinutes = 15,
        [int]$PollSeconds = 30,
        [bool]$RequireDeviceAuthSuccess = $true,
        [ref]$Joined
    )

    $Joined.Value = $false
    $maxChecks = [math]::Ceiling(($TimeoutMinutes * 60) / $PollSeconds)

    $checkScript = @'
$ErrorActionPreference = 'SilentlyContinue'

$status = dsregcmd /status 2>&1
$statusText = ($status -join "`n")

$azureAdJoined = 'UNKNOWN'
$deviceAuthStatus = 'UNKNOWN'
$mdmUrlPresent = 'UNKNOWN'

if ($statusText -match 'AzureAdJoined\s*:\s*(\S+)') {
    $azureAdJoined = $Matches[1]
}

if ($statusText -match 'DeviceAuthStatus\s*:\s*(\S+)') {
    $deviceAuthStatus = $Matches[1]
}

if ($statusText -match 'MdmUrl\s*:\s*(\S+)') {
    $mdmUrlPresent = if ([string]::IsNullOrWhiteSpace($Matches[1])) { 'NO' } else { 'YES' }
}

Write-Output "AVD_ENTRA_JOIN_AzureAdJoined=$azureAdJoined"
Write-Output "AVD_ENTRA_JOIN_DeviceAuthStatus=$deviceAuthStatus"
Write-Output "AVD_ENTRA_JOIN_MdmUrlPresent=$mdmUrlPresent"
'@

    Write-Log -Level 'INFO' -Component 'ENTRA' -Message ("Waiting for Microsoft Entra join to complete on '{0}' before installing the AVD agent. Timeout: {1} minute(s)." -f $VmName, $TimeoutMinutes)

    for ($i = 1; $i -le $maxChecks; $i++) {
        try {
            $result = Invoke-AzVMRunCommand `
                -ResourceGroupName $SessionHostResourceGroupName `
                -VMName $VmName `
                -CommandId 'RunPowerShellScript' `
                -ScriptString $checkScript `
                -ErrorAction Stop

            $messages = @($result.Value | ForEach-Object { $_.Message }) -join "`n"

            $azureAdJoined = 'UNKNOWN'
            $deviceAuthStatus = 'UNKNOWN'
            $mdmUrlPresent = 'UNKNOWN'

            if ($messages -match 'AVD_ENTRA_JOIN_AzureAdJoined=(\S+)') {
                $azureAdJoined = $Matches[1]
            }

            if ($messages -match 'AVD_ENTRA_JOIN_DeviceAuthStatus=(\S+)') {
                $deviceAuthStatus = $Matches[1]
            }

            if ($messages -match 'AVD_ENTRA_JOIN_MdmUrlPresent=(\S+)') {
                $mdmUrlPresent = $Matches[1]
            }

            Write-Log -Level 'INFO' -Component 'ENTRA' -Message ("Entra join check {0}/{1} for '{2}': AzureAdJoined={3}; DeviceAuthStatus={4}; MdmUrlPresent={5}" -f $i, $maxChecks, $VmName, $azureAdJoined, $deviceAuthStatus, $mdmUrlPresent)

            $isAzureAdJoined = ($azureAdJoined -eq 'YES')
            $isDeviceAuthOk = (-not $RequireDeviceAuthSuccess) -or ($deviceAuthStatus -eq 'SUCCESS')

            if ($isAzureAdJoined -and $isDeviceAuthOk) {
                Write-Log -Level 'SUCCESS' -Component 'ENTRA' -Message ("Microsoft Entra join completed on '{0}'." -f $VmName)
                $Joined.Value = $true
                return
            }
        }
        catch {
            Write-Log -Level 'WARN' -Component 'ENTRA' -Message ("Unable to check Entra join status on '{0}' yet: {1}" -f $VmName, $_.Exception.Message)
        }

        Start-Sleep -Seconds $PollSeconds
    }
}

function Install-AvdAgentAndRegisterHost {
    param(
        [string]$VmName,
        [string]$RegistrationToken
    )

    $installRdsRole = if ($InstallRdsRoleOnServerOS) { '$true' } else { '$false' }

    $runScript = @"
`$ErrorActionPreference = 'Stop'
`$ConfirmPreference = 'None'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

`$work = 'C:\AVDInstall'
if (-not (Test-Path `$work)) {
    New-Item -ItemType Directory -Path `$work -Force | Out-Null
}
Set-Location `$work

if ($installRdsRole) {
    try {
        Install-WindowsFeature -Name RDS-RD-Server -IncludeManagementTools -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Output "RDS role install may not apply to this OS: `$(`$_.Exception.Message)"
    }
}

`$uris = @(
    'https://go.microsoft.com/fwlink/?linkid=2310011',
    'https://go.microsoft.com/fwlink/?linkid=2311028'
)

`$installers = @()
foreach (`$uri in `$uris) {
    `$expandedUri = (Invoke-WebRequest -MaximumRedirection 0 -Uri `$uri -UseBasicParsing -ErrorAction SilentlyContinue).Headers.Location
    if (-not `$expandedUri) {
        `$expandedUri = `$uri
    }

    `$fileName = (`$expandedUri.Split('/')[-1]).Split('?')[0]
    `$outFile = Join-Path `$work `$fileName
    Invoke-WebRequest -Uri `$expandedUri -UseBasicParsing -OutFile `$outFile
    Unblock-File -Path `$outFile
    `$installers += `$outFile
}

`$agent = `$installers | Where-Object { `$_ -match 'RDAgent' } | Select-Object -First 1
`$bootLoader = `$installers | Where-Object { `$_ -match 'BootLoader' } | Select-Object -First 1

if (-not `$agent -or -not `$bootLoader) {
    throw 'Could not identify AVD agent or bootloader installer.'
}

Start-Process msiexec.exe -ArgumentList @('/i', `$agent, '/quiet', '/qn', 'REGISTRATIONTOKEN=$RegistrationToken') -Wait -NoNewWindow
Start-Process msiexec.exe -ArgumentList @('/i', `$bootLoader, '/quiet', '/qn') -Wait -NoNewWindow

Write-Output 'AVD agent and bootloader installation complete.'
"@

    Write-Log "Installing AVD agent on '$VmName'..."
    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $SessionHostResourceGroupName `
        -VMName $VmName `
        -CommandId 'RunPowerShellScript' `
        -ScriptString $runScript

    $result.Value | ForEach-Object { Write-Output $_.Message }
}

try {
    Connect-RunbookAz
    Test-JoinConfiguration

    Write-StepBanner -Message 'VALIDATION'
    Write-Log -Level 'INFO' -Component 'VALIDATION' -Message "Validating host pool..."
    Get-AzWvdHostPool -ResourceGroupName $HostPoolResourceGroupName -Name $HostPoolName | Out-Null

    Write-Log -Level 'INFO' -Component 'KEYVAULT' -Message "Retrieving local admin credential from Key Vault '$KeyVaultName'..."
    $localAdminCredential = Get-PSCredentialFromKeyVault `
        -VaultName $KeyVaultName `
        -UsernameSecretName $LocalAdminUsernameSecretName `
        -PasswordSecretName $LocalAdminPasswordSecretName
    Write-Log -Level 'SUCCESS' -Component 'KEYVAULT' -Message "Local admin credential retrieved successfully."

    $domainJoinCredential = $null
    if ($JoinType -eq 'ADDS') {
        Write-Log -Level 'INFO' -Component 'KEYVAULT' -Message "Retrieving AD DS join credential from Key Vault '$KeyVaultName'..."
        $domainJoinCredential = Get-PSCredentialFromKeyVault `
            -VaultName $KeyVaultName `
            -UsernameSecretName $DomainJoinUsernameSecretName `
            -PasswordSecretName $DomainJoinPasswordSecretName
        Write-Log -Level 'SUCCESS' -Component 'KEYVAULT' -Message "AD DS join credential retrieved successfully."
    }

    $existingHostVmNames = @(Get-ExistingSessionHostVmNames)
    $existingHostCount = $existingHostVmNames.Count

    Write-StepBanner -Message 'DEPLOYMENT PLAN'
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("JoinType           : {0}" -f $JoinType)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Enable Intune     : {0}" -f ([bool]$EnableIntuneEnrollment))
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Host pool          : {0}" -f $HostPoolName)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("VM prefix          : {0}" -f $VmNamePrefix)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Requested hosts    : {0}" -f $SessionHostCount)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("OverwriteExisting  : {0}" -f ([bool]$OverwriteExisting))
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Existing host count: {0}" -f $existingHostCount)

    if ($existingHostCount -gt 0) {
        Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Existing session host VM names: {0}" -f ($existingHostVmNames -join ', '))
    }
    else {
        Write-Log -Level 'INFO' -Component 'PLAN' -Message "No existing session hosts found in host pool."
    }

    if ([bool]$OverwriteExisting) {
        Write-Log -Level 'WARN' -Component 'PLAN' -Message "OverwriteExisting is True. Existing session hosts and their VM resources will be removed before creating replacements."

        if ($existingHostCount -gt 0) {
            Write-StepBanner -Message 'DELETE EXISTING HOSTS'
            Invoke-DrainAndDeleteExistingHosts -DomainJoinCredential $domainJoinCredential
        }

        $targetVmNames = @(Get-NextVmNamesForHostPoolCount -Prefix $VmNamePrefix -Count $SessionHostCount -ExistingHostCount 0)
        Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Replacement hosts to create: {0}" -f ($targetVmNames -join ', '))
    }
    else {
        Write-Log -Level 'INFO' -Component 'PLAN' -Message "OverwriteExisting is False. Existing hosts will be retained. New host numbering will continue from the current host pool count, regardless of VM prefix."
        $targetVmNames = @(Get-NextVmNamesForHostPoolCount -Prefix $VmNamePrefix -Count $SessionHostCount -ExistingHostCount $existingHostCount)
        Write-Log -Level 'INFO' -Component 'PLAN' -Message ("New hosts to create: {0}" -f ($targetVmNames -join ', '))
    }

    Write-StepBanner -Message 'IMAGE SELECTION'

    $imageVersionId = Get-LatestGalleryImageVersionId `
        -ResourceGroupName $GalleryResourceGroupName `
        -GalleryName $GalleryName `
        -ImageDefinitionName $GalleryImageDefinitionName

    Write-Log -Level 'SUCCESS' -Component 'IMAGE' -Message ("Using latest gallery image version: {0}" -f $imageVersionId)

    $registrationToken = $null
    Get-HostPoolRegistrationToken -RegistrationToken ([ref]$registrationToken)

    for ($i = 0; $i -lt $targetVmNames.Count; $i++) {
        $vmName = $targetVmNames[$i]
        $deployOrdinal = [Array]::IndexOf($targetVmNames, $vmName) + 1
        Write-StepBanner -Message ("DEPLOYMENT {0} OF {1}" -f $deployOrdinal, $targetVmNames.Count)
        Write-Log -Level 'INFO' -Component 'DEPLOY' -Message ("Starting deployment for VM '{0}'" -f $vmName)

        New-SessionHostVm `
            -VmName $vmName `
            -ImageVersionId $imageVersionId `
            -LocalAdminCredential $localAdminCredential

        switch ($JoinType) {
            'ADDS' {
                Join-SessionHostAdDs `
                    -VmName $vmName `
                    -DomainJoinCredential $domainJoinCredential
            }
            'ENTRA' {
                Join-SessionHostEntra `
                    -VmName $vmName
            }
            default {
                throw "Unsupported JoinType '$JoinType'."
            }
        }

        Install-AvdAgentAndRegisterHost `
            -VmName $vmName `
            -RegistrationToken $registrationToken

        $registered = $false
        Wait-ForSessionHostRegistration `
            -ExpectedVmName $vmName `
            -TimeoutMinutes $RegistrationTimeoutMinutes `
            -Registered ([ref]$registered)

        if (-not $registered) {
            throw "VM '$vmName' did not register into host pool '$HostPoolName' within the timeout."
        }

        Write-Log -Level 'SUCCESS' -Component 'DEPLOY' -Message ("Completed deployment for VM '{0}'" -f $vmName)

        if ($i -lt ($targetVmNames.Count - 1) -and $VmCreationThrottleSeconds -gt 0) {
            Start-Sleep -Seconds $VmCreationThrottleSeconds
        }
    }

    Write-StepBanner -Message 'COMPLETE'
    Write-Log -Level 'SUCCESS' -Component 'RUNBOOK' -Message "Runbook completed successfully."
}
catch {
    Throw-RunbookError -Step "RUNBOOK" -ErrorRecord $_
}
