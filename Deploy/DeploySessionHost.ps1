<#
.SYNOPSIS
AVD production deployment runbook for Azure Automation.

.DESCRIPTION
Environment configuration is hardcoded at the top of the script for safety.
Only runtime controls remain in the param block.

RUNTIME PARAMETERS
- VmNamePrefix
- SessionHostCount
- JoinType
- AppendToExistingPrefix
- DeleteExistingHosts

JOIN TYPES
- ADDS  = classic Active Directory / Entra Domain Services join using Key Vault credentials
- ENTRA = Microsoft Entra join using AADLoginForWindows extension, with Intune enrollment dependent on tenant-side MDM configuration

NOTES
- Replace the placeholder values in the ENVIRONMENT CONFIG section before use.
- Local admin credentials are read from Key Vault.
- ADDS join credentials are read from Key Vault when JoinType = ADDS.
- This runbook is intended for Azure Automation with a managed identity.
#>

# ==========================================
# ENVIRONMENT CONFIG - PROD
# Replace all placeholder values before use
# ==========================================

$SubscriptionId                    = "00000000-0000-0000-0000-000000000000"
$Location                          = "uksouth"

$HostPoolResourceGroupName         = "rg-avd-prod"

$SessionHostResourceGroupName      = "rg-avd-prod-sh"

$GalleryResourceGroupName          = "rg-avd-images-prod"
$GalleryName                       = "acgAvdProd"

$VirtualNetworkResourceGroupName   = "rg-network-prod"
$VirtualNetworkName                = "vnet-avd-prod"
$SubnetName                        = "snet-avd-sessionhosts"

$VmSize                            = "Standard_D4s_v5"

$KeyVaultName                      = "kv-avd-prod"
$LocalAdminUsernameSecretName      = "avd-localadmin-username"
$LocalAdminPasswordSecretName      = "avd-localadmin-password"

# ADDS join settings
$DomainFqdn                        = "corp.contoso.com"
$DomainOuPath                      = "OU=AVD,OU=Servers,DC=corp,DC=contoso,DC=com"
$DomainJoinUsernameSecretName      = "avd-domainjoin-username"
$DomainJoinPasswordSecretName      = "avd-domainjoin-password"

# ENTRA join settings
$TenantId                          = "00000000-0000-0000-0000-000000000000"
$EnableIntuneEnrollment            = $true

# Optional defaults
$DrainModeBeforeDelete             = $false
$ForceLogoffUsers                  = $false
$InstallRdsRoleOnServerOS          = $false
$RegistrationTokenHours            = 24
$VmCreationThrottleSeconds         = 10
$VmReadyTimeoutMinutes             = 25
$RegistrationTimeoutMinutes        = 25
$Tags                              = @{
    "Workload"    = "AVD"
    "Environment" = "Prod"
    "ManagedBy"   = "AzureAutomation"
}

param(
    [Parameter(Mandatory = $true)]
    [string]$VmNamePrefix,

    [Parameter(Mandatory = $true)]
    [int]$SessionHostCount,

    [Parameter(Mandatory = $true)]
    [ValidateSet('ADDS','ENTRA')]
    [string]$JoinType,

    [Parameter(Mandatory = $true)]
    [string]$HostPoolName,

    [Parameter(Mandatory = $true)]
    [string]$GalleryImageDefinitionName,

    [Parameter(Mandatory = $false)]
    [bool]$AppendToExistingPrefix = $true,

    [Parameter(Mandatory = $false)]
    [bool]$DeleteExistingHosts = $false
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')]
        [string]$Level = 'INFO',
        [string]$Message,
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

function Get-PrefixedExistingSessionHostVmNames {
    param([string]$Prefix)

    $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName -ErrorAction SilentlyContinue
    if (-not $sessionHosts) {
        return @()
    }

    $names = @()
    foreach ($sessionHost in $sessionHosts) {
        $shortVmName = Get-SessionHostShortName -SessionHostName $sessionHost.Name
        if ($shortVmName -and $shortVmName.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $names += $shortVmName
        }
    }

    return @($names | Sort-Object -Unique)
}

function Get-NextVmNamesForPrefix {
    param(
        [string]$Prefix,
        [int]$Count
    )

    $existingNames = Get-PrefixedExistingSessionHostVmNames -Prefix $Prefix
    $highest = 0

    foreach ($name in $existingNames) {
        if ($name -match ('^' + [regex]::Escape($Prefix) + '-(\d+)$')) {
            $num = [int]$Matches[1]
            if ($num -gt $highest) {
                $highest = $num
            }
        }
    }

    $newNames = @()
    for ($i = 1; $i -le $Count; $i++) {
        $newNames += ('{0}-{1:D2}' -f $Prefix, ($highest + $i))
    }

    return @{
        ExistingNames = $existingNames
        NewNames      = $newNames
        HighestSuffix = $highest
    }
}

function Wait-ForVmPowerState {
    param(
        [string]$ResourceGroupName,
        [string]$VmName,
        [string[]]$DesiredStates,
        [int]$TimeoutMinutes = 20,
        [int]$PollSeconds = 20
    )

    $maxChecks = [math]::Ceiling(($TimeoutMinutes * 60) / $PollSeconds)

    for ($i = 1; $i -le $maxChecks; $i++) {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status
        $powerState = ($vm.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1).DisplayStatus
        Write-Log "VM '$VmName' power state: $powerState"
        if ($DesiredStates -contains $powerState) {
            return $true
        }
        Start-Sleep -Seconds $PollSeconds
    }

    return $false
}

function Wait-ForSessionHostRegistration {
    param(
        [string]$ExpectedVmName,
        [int]$TimeoutMinutes = 20,
        [int]$PollSeconds = 30
    )

    $maxChecks = [math]::Ceiling(($TimeoutMinutes * 60) / $PollSeconds)

    for ($i = 1; $i -le $maxChecks; $i++) {
        $hosts = Get-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName -ErrorAction SilentlyContinue
        $match = $hosts | Where-Object {
            $short = Get-SessionHostShortName -SessionHostName $_.Name
            $short -eq $ExpectedVmName
        }

        if ($match) {
            Write-Log "Session host '$ExpectedVmName' is now registered in host pool '$HostPoolName'."
            return $true
        }

        Write-Log "Waiting for session host '$ExpectedVmName' to register..."
        Start-Sleep -Seconds $PollSeconds
    }

    return $false
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

    return $token.Token
}

function Invoke-DrainAndDeleteExistingHosts {
    Write-Log "Enumerating existing session hosts in host pool '$HostPoolName'..."
    $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $HostPoolResourceGroupName -HostPoolName $HostPoolName -ErrorAction SilentlyContinue

    if (-not $sessionHosts) {
        Write-Log "No existing session hosts found."
        return
    }

    foreach ($sessionHost in $sessionHosts) {
        $sessionHostName = $sessionHost.Name
        $shortVmName = Get-SessionHostShortName -SessionHostName $sessionHostName
        $vmName = Get-SessionHostVmNameFromResourceId -ResourceId $sessionHost.ResourceId
        if (-not $vmName) { $vmName = $shortVmName }

        Write-Log "Processing existing session host '$sessionHostName' (VM: '$vmName')..."

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

    Write-Log "Creating NIC '$nicName'..."
    $nic = New-AzNetworkInterface `
        -Name $nicName `
        -ResourceGroupName $SessionHostResourceGroupName `
        -Location $Location `
        -SubnetId $subnet.Id

    Write-Log "Building VM config for '$VmName'..."
    $vmConfig = New-AzVMConfig -VMName $VmName -VMSize $VmSize
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

    $isReady = Wait-ForVmPowerState `
        -ResourceGroupName $SessionHostResourceGroupName `
        -VmName $VmName `
        -DesiredStates @('VM running') `
        -TimeoutMinutes $VmReadyTimeoutMinutes

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

    $isReady = Wait-ForVmPowerState `
        -ResourceGroupName $SessionHostResourceGroupName `
        -VmName $VmName `
        -DesiredStates @('VM running') `
        -TimeoutMinutes $VmReadyTimeoutMinutes

    if (-not $isReady) {
        throw "VM '$VmName' did not return to running after AD DS join."
    }
}

function Join-SessionHostEntra {
    param(
        [string]$VmName
    )

    Write-Log "Enabling Microsoft Entra sign-in extension on '$VmName'..."
    Set-AzVMExtension `
        -ResourceGroupName $SessionHostResourceGroupName `
        -VMName $VmName `
        -Location $Location `
        -Publisher 'Microsoft.Azure.ActiveDirectory' `
        -ExtensionType 'AADLoginForWindows' `
        -Name 'AADLoginForWindows' `
        -TypeHandlerVersion '2.2' `
        -EnableAutomaticUpgrade $true | Out-Null

    Write-Log "Microsoft Entra sign-in extension applied to '$VmName'."

    if ($EnableIntuneEnrollment) {
        Write-Log "EnableIntuneEnrollment is set. Intune enrollment must be enabled by tenant-side MDM auto-enrollment configuration and licensing."
        Write-Log "This runbook does not force tenant enrollment policy; it assumes Intune auto-enrollment prerequisites are already configured."
    }
}

function Install-AvdAgentAndRegisterHost {
    param(
        [string]$VmName,
        [string]$RegistrationToken
    )

    $installRdsRole = $InstallRdsRoleOnServerOS.IsPresent.ToString().ToLower()

    $runScript = @"
`$ErrorActionPreference = 'Stop'
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
        Write-Output "RDS role install may not apply to this OS: $($_.Exception.Message)"
    }
}

`$uris = @(
    'https://go.microsoft.com/fwlink/?linkid=2310011',
    'https://go.microsoft.com/fwlink/?linkid=2311028'
)

`$installers = @()
foreach (`$uri in `$uris) {
    `$expandedUri = (Invoke-WebRequest -MaximumRedirection 0 -Uri `$uri -ErrorAction SilentlyContinue).Headers.Location
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

Start-Process msiexec.exe -ArgumentList "/i `"`$agent`" /quiet /qn REGISTRATIONTOKEN=$RegistrationToken" -Wait -NoNewWindow
Start-Process msiexec.exe -ArgumentList "/i `"`$bootLoader`" /quiet /qn" -Wait -NoNewWindow

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

    $vmPlan = Get-NextVmNamesForPrefix -Prefix $VmNamePrefix -Count $SessionHostCount
    $existingPrefixedHosts = @($vmPlan.ExistingNames)
    $targetVmNames = @($vmPlan.NewNames)

    Write-StepBanner -Message 'DEPLOYMENT PLAN'
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("JoinType               : {0}" -f $JoinType)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Host pool              : {0}" -f $HostPoolName)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("VM prefix              : {0}" -f $VmNamePrefix)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Requested new hosts    : {0}" -f $SessionHostCount)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("AppendToExistingPrefix : {0}" -f $AppendToExistingPrefix)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("DeleteExistingHosts    : {0}" -f ([bool]$DeleteExistingHosts))

    if ($existingPrefixedHosts.Count -gt 0) {
        Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Found {0} existing session host(s) using prefix '{1}': {2}" -f $existingPrefixedHosts.Count, $VmNamePrefix, ($existingPrefixedHosts -join ', '))
        Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Highest existing numeric suffix: {0}" -f $vmPlan.HighestSuffix)

        if ($AppendToExistingPrefix) {
            Write-Log -Level 'WARN' -Component 'PLAN' -Message "Prefix match detected and AppendToExistingPrefix is True. Existing matching hosts will be retained."
            Write-Log -Level 'INFO' -Component 'PLAN' -Message ("New hosts to create: {0}" -f ($targetVmNames -join ', '))
        }
        else {
            Write-Log -Level 'WARN' -Component 'PLAN' -Message "Prefix match detected but AppendToExistingPrefix is False. Standard deletion behavior will be used if DeleteExistingHosts is enabled."

            if ([bool]$DeleteExistingHosts) {
                Write-StepBanner -Message 'DELETE EXISTING HOSTS'
                Invoke-DrainAndDeleteExistingHosts
                $targetVmNames = @()
                for ($i = 1; $i -le $SessionHostCount; $i++) {
                    $targetVmNames += ('{0}-{1:D2}' -f $VmNamePrefix, $i)
                }
                Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Replacement hosts to create after deletion: {0}" -f ($targetVmNames -join ', '))
            }
            else {
                Write-Log -Level 'WARN' -Component 'PLAN' -Message "DeleteExistingHosts is False, so no deletion will occur. New hosts will still be appended to avoid name collision."
                Write-Log -Level 'INFO' -Component 'PLAN' -Message ("New hosts to create: {0}" -f ($targetVmNames -join ', '))
            }
        }
    }
    else {
        Write-Log -Level 'INFO' -Component 'PLAN' -Message ("No existing hosts found using prefix '{0}'." -f $VmNamePrefix)

        if ([bool]$DeleteExistingHosts) {
            Write-StepBanner -Message 'DELETE EXISTING HOSTS'
            Invoke-DrainAndDeleteExistingHosts
        }
        else {
            Write-Log -Level 'INFO' -Component 'PLAN' -Message "DeleteExistingHosts is False. Existing non-matching hosts will be retained."
        }

        Write-Log -Level 'INFO' -Component 'PLAN' -Message ("New hosts to create: {0}" -f ($targetVmNames -join ', '))
    }

    Write-StepBanner -Message 'IMAGE SELECTION'

    $imageVersionId = Get-LatestGalleryImageVersionId `
        -ResourceGroupName $GalleryResourceGroupName `
        -GalleryName $GalleryName `
        -ImageDefinitionName $GalleryImageDefinitionName

    Write-Log -Level 'SUCCESS' -Component 'IMAGE' -Message ("Using latest gallery image version: {0}" -f $imageVersionId)

    $registrationToken = Get-HostPoolRegistrationToken

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

        $registered = Wait-ForSessionHostRegistration `
            -ExpectedVmName $vmName `
            -TimeoutMinutes $RegistrationTimeoutMinutes

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
