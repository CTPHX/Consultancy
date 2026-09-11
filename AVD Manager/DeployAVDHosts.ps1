<#
.SYNOPSIS
Reusable AVD session-host deployment runbook for AVD Manager and Azure Automation.

.DESCRIPTION
AVD Manager supplies the selected host-pool mapping and deployment-time choices as
parameters. The runbook keeps only operational timeouts and implementation defaults
internally, so one published runbook can safely service multiple host pools and
customer environments.

AVD MANAGER OWNS
- Drain/grace-period orchestration.
- Optional forced user logoff at the grace deadline.
- Durable operation state and restart recovery.
- The final pre-submit live user-session check.

THIS RUNBOOK OWNS
- A second fail-closed zero-session check immediately before destructive replacement.
- Optional temporary scaling-plan disable/restore.
- Removal of existing hosts when OverwriteExisting is true.
- VM creation, join, AVD agent installation and registration.

SAFETY BEHAVIOUR
- This runbook never force-logs-off users.
- Existing session hosts are put/kept in drain mode before replacement.
- User-session enumeration uses ErrorAction Stop and replacement fails closed.
- If any session remains, nothing is deleted.
- Image, network, host-pool and Key Vault dependencies are preflighted before deletion.
- Scaling plans disabled by this run are restored on success and best-effort on failure.

JOIN TYPES
- ADDS  = classic Active Directory / Entra Domain Services join using Key Vault credentials.
- ENTRA = Microsoft Entra join using AADLoginForWindows, with optional Intune enrollment.

NOTES
- Secret VALUES are never passed as parameters. Only Key Vault and secret names are supplied.
- GalleryImageVersion accepts Latest or an exact version such as 0.0.1.
- VmSize defaults to Standard_D2ds_v6 but can be overridden by AVD Manager.
- Intended for Azure Automation using the Automation Account managed identity.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$HostPoolName,

    [Parameter(Mandatory = $true)]
    [string]$HostPoolResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$SessionHostResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VmNamePrefix,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 20)]
    [int]$SessionHostCount,

    [Parameter(Mandatory = $false)]
    [bool]$OverwriteExisting = $false,

    [Parameter(Mandatory = $false)]
    [string]$VmSize = "Standard_D2ds_v6",

    [Parameter(Mandatory = $true)]
    [string]$GalleryResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$GalleryName,

    [Parameter(Mandatory = $true)]
    [string]$GalleryImageDefinitionName,

    [Parameter(Mandatory = $false)]
    [string]$GalleryImageVersion = "Latest",

    [Parameter(Mandatory = $true)]
    [string]$VirtualNetworkResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$VirtualNetworkName,

    [Parameter(Mandatory = $true)]
    [string]$SubnetName,

    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $false)]
    [ValidateSet('ADDS','ENTRA')]
    [string]$JoinType = "ADDS",

    [Parameter(Mandatory = $false)]
    [string]$LocalAdminUsernameSecretName = "adm-local-upn",

    [Parameter(Mandatory = $false)]
    [string]$LocalAdminPasswordSecretName = "adm-local-pw",

    [Parameter(Mandatory = $false)]
    [string]$DomainFqdn = "",

    [Parameter(Mandatory = $false)]
    [string]$DomainOuPath = "",

    [Parameter(Mandatory = $false)]
    [string]$DomainJoinUsernameSecretName = "domainjoin-upn",

    [Parameter(Mandatory = $false)]
    [string]$DomainJoinPasswordSecretName = "domainjoin-pw",

    [Parameter(Mandatory = $false)]
    [string]$TenantId = "",

    [Parameter(Mandatory = $false)]
    [bool]$EnableIntuneEnrollment = $true,

    [Parameter(Mandatory = $false)]
    [string]$IntuneMdmId = "0000000a-0000-0000-c000-000000000000",

    [Parameter(Mandatory = $false)]
    [bool]$InstallRdsRoleOnServerOS = $false,

    [Parameter(Mandatory = $false)]
    [bool]$RequireEntraDeviceAuthSuccess = $true,

    [Parameter(Mandatory = $false)]
    [bool]$TemporarilyDisableScalingDuringDeployment = $true,

    [Parameter(Mandatory = $false)]
    [string]$EnvironmentTag = "Prod"
)

# ==========================================
# INTERNAL OPERATIONAL DEFAULTS
# These are deliberately not normal UI fields.
# AVD Manager supplies environment/host-pool mappings as runbook parameters.
# ==========================================
$RegistrationTokenHours      = 24
$VmCreationThrottleSeconds  = 10
$VmReadyTimeoutMinutes      = 25
$RegistrationTimeoutMinutes = 25
$EntraJoinWaitTimeoutMinutes = 15
$EntraJoinWaitPollSeconds   = 30

$Tags = @{
    "Workload"    = "AVD"
    "Environment" = $EnvironmentTag
    "ManagedBy"   = "AVDManager"
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

function Test-DeploymentInputs {
    Write-Log -Level 'INFO' -Component 'VALIDATION' -Message 'Validating deployment-time parameters...'

    $requiredStrings = [ordered]@{
        SubscriptionId                  = $SubscriptionId
        Location                        = $Location
        HostPoolName                    = $HostPoolName
        HostPoolResourceGroupName       = $HostPoolResourceGroupName
        SessionHostResourceGroupName    = $SessionHostResourceGroupName
        VmNamePrefix                    = $VmNamePrefix
        VmSize                          = $VmSize
        GalleryResourceGroupName        = $GalleryResourceGroupName
        GalleryName                     = $GalleryName
        GalleryImageDefinitionName      = $GalleryImageDefinitionName
        VirtualNetworkResourceGroupName = $VirtualNetworkResourceGroupName
        VirtualNetworkName              = $VirtualNetworkName
        SubnetName                      = $SubnetName
        KeyVaultName                    = $KeyVaultName
        LocalAdminUsernameSecretName    = $LocalAdminUsernameSecretName
        LocalAdminPasswordSecretName    = $LocalAdminPasswordSecretName
    }

    foreach ($entry in $requiredStrings.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
            throw "$($entry.Key) cannot be empty."
        }
    }

    $subscriptionGuid = [guid]::Empty
    if (-not [guid]::TryParse($SubscriptionId, [ref]$subscriptionGuid)) {
        throw "SubscriptionId '$SubscriptionId' is not a valid GUID."
    }

    if ($VmNamePrefix.Length -gt 12) {
        throw "VmNamePrefix '$VmNamePrefix' is too long. Maximum length is 12 characters so generated Windows computer names remain within 15 characters including the -NN suffix."
    }

    if ($VmNamePrefix -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$') {
        throw "VmNamePrefix '$VmNamePrefix' is invalid. Use letters, numbers and hyphens only, and do not start or end with a hyphen."
    }

    if ([string]::IsNullOrWhiteSpace($GalleryImageVersion)) {
        $script:GalleryImageVersion = 'Latest'
    }

    if ($GalleryImageVersion -ne 'Latest' -and $GalleryImageVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "GalleryImageVersion '$GalleryImageVersion' is invalid. Use 'Latest' or a gallery version in Major.Minor.Patch format, for example 0.0.1."
    }

    Write-Log -Level 'SUCCESS' -Component 'VALIDATION' -Message 'Deployment-time parameters are valid.'
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

function Test-TargetVmNames {
    param(
        [string[]]$VmNames
    )

    foreach ($name in $VmNames) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "A generated VM name was empty."
        }

        if ($name.Length -gt 15) {
            throw "Generated VM name '$name' is $($name.Length) characters long. Windows computer names must remain within 15 characters. Shorten VmNamePrefix."
        }

        if ($name -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$') {
            throw "Generated VM name '$name' is invalid. Use a VmNamePrefix containing letters, numbers and hyphens only."
        }
    }
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

function Resolve-GalleryImageVersion {
    param(
        [string]$ResourceGroupName,
        [string]$GalleryName,
        [string]$ImageDefinitionName,
        [string]$RequestedVersion = 'Latest'
    )

    $versions = @(
        Get-AzGalleryImageVersion `
            -ResourceGroupName $ResourceGroupName `
            -GalleryName $GalleryName `
            -GalleryImageDefinitionName $ImageDefinitionName
    )

    if (-not $versions -or $versions.Count -eq 0) {
        throw "No image versions found for '$ImageDefinitionName' in gallery '$GalleryName'."
    }

    if ([string]::IsNullOrWhiteSpace($RequestedVersion) -or $RequestedVersion -eq 'Latest') {
        $selected = $versions | Sort-Object { [version]$_.Name } | Select-Object -Last 1
    }
    else {
        $selected = $versions |
            Where-Object { $_.Name -eq $RequestedVersion } |
            Select-Object -First 1

        if (-not $selected) {
            $availableVersions = @($versions | Sort-Object { [version]$_.Name } | ForEach-Object { $_.Name })
            throw "Gallery image version '$RequestedVersion' was not found for '$ImageDefinitionName'. Available versions: $($availableVersions -join ', ')."
        }
    }

    return [pscustomobject]@{
        Id      = $selected.Id
        Version = $selected.Name
    }
}

function Test-DeploymentEnvironment {
    Write-StepBanner -Message 'PREFLIGHT'
    Write-Log -Level 'INFO' -Component 'PREFLIGHT' -Message 'Validating host-pool, compute, image, network and Key Vault dependencies before any destructive action...'

    $hostPool = Get-AzWvdHostPool `
        -ResourceGroupName $HostPoolResourceGroupName `
        -Name $HostPoolName `
        -ErrorAction Stop

    if (-not $hostPool) {
        throw "Host pool '$HostPoolName' was not found in resource group '$HostPoolResourceGroupName'."
    }

    Get-AzResourceGroup -Name $SessionHostResourceGroupName -ErrorAction Stop | Out-Null

    $vnet = Get-AzVirtualNetwork `
        -Name $VirtualNetworkName `
        -ResourceGroupName $VirtualNetworkResourceGroupName `
        -ErrorAction Stop

    $subnet = $vnet | Get-AzVirtualNetworkSubnetConfig | Where-Object { $_.Name -eq $SubnetName } | Select-Object -First 1
    if (-not $subnet) {
        throw "Subnet '$SubnetName' was not found in VNet '$VirtualNetworkName' in resource group '$VirtualNetworkResourceGroupName'."
    }

    Get-AzGallery `
        -ResourceGroupName $GalleryResourceGroupName `
        -Name $GalleryName `
        -ErrorAction Stop | Out-Null

    $imageSelection = Resolve-GalleryImageVersion `
        -ResourceGroupName $GalleryResourceGroupName `
        -GalleryName $GalleryName `
        -ImageDefinitionName $GalleryImageDefinitionName `
        -RequestedVersion $GalleryImageVersion

    Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction Stop | Out-Null

    Write-Log -Level 'SUCCESS' -Component 'PREFLIGHT' -Message ("Preflight passed. Host pool '{0}', subnet '{1}', image '{2}' version '{3}' and Key Vault '{4}' are available." -f $HostPoolName, $SubnetName, $GalleryImageDefinitionName, $imageSelection.Version, $KeyVaultName)

    return [pscustomobject]@{
        HostPool       = $hostPool
        SubnetId       = $subnet.Id
        ImageSelection = $imageSelection
    }
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
    $sessionHosts = @(
        Get-AzWvdSessionHost `
            -ResourceGroupName $HostPoolResourceGroupName `
            -HostPoolName $HostPoolName `
            -ErrorAction Stop
    )

    if (-not $sessionHosts -or $sessionHosts.Count -eq 0) {
        Write-Log "No existing session hosts found."
        return
    }

    $sessionHostStates = @()

    foreach ($sessionHost in $sessionHosts) {
        $sessionHostFullName = $sessionHost.Name
        $sessionHostName = ($sessionHostFullName -split '/')[-1]
        $shortVmName = Get-SessionHostShortName -SessionHostName $sessionHostName
        $vmName = Get-SessionHostVmNameFromResourceId -ResourceId $sessionHost.ResourceId
        if (-not $vmName) { $vmName = $shortVmName }

        $sessionHostStates += [pscustomobject]@{
            SessionHostFullName = $sessionHostFullName
            SessionHostName     = $sessionHostName
            VmName              = $vmName
        }
    }

    Write-Log -Level 'INFO' -Component 'AVD' -Message ("Performing final replacement safety check for {0} existing session host(s)." -f $sessionHostStates.Count)

    foreach ($state in $sessionHostStates) {
        Write-Log -Level 'INFO' -Component 'AVD' -Message ("Ensuring drain mode is enabled for '{0}'..." -f $state.SessionHostName)

        Update-AzWvdSessionHost `
            -ResourceGroupName $HostPoolResourceGroupName `
            -HostPoolName $HostPoolName `
            -Name $state.SessionHostName `
            -AllowNewSession:$false | Out-Null
    }

    $sessionsFound = @()

    foreach ($state in $sessionHostStates) {
        $userSessions = @(
            Get-AzWvdUserSession `
                -ResourceGroupName $HostPoolResourceGroupName `
                -HostPoolName $HostPoolName `
                -SessionHostName $state.SessionHostName `
                -ErrorAction Stop
        )

        foreach ($userSession in $userSessions) {
            $userLabel = $userSession.UserPrincipalName
            if ([string]::IsNullOrWhiteSpace($userLabel)) {
                $userLabel = $userSession.ActiveDirectoryUserName
            }
            if ([string]::IsNullOrWhiteSpace($userLabel)) {
                $userLabel = "Session $($userSession.Id)"
            }

            $sessionsFound += [pscustomobject]@{
                SessionHostName = $state.SessionHostName
                UserLabel       = $userLabel
                Id              = $userSession.Id
            }
        }
    }

    if ($sessionsFound.Count -gt 0) {
        $sessionSummary = @(
            $sessionsFound |
                ForEach-Object { "{0}: {1}" -f $_.SessionHostName, $_.UserLabel }
        ) -join '; '

        Write-Log -Level 'ERROR' -Component 'AVD' -Message ("Replacement stopped because {0} user session(s) are still present. No session hosts or VMs have been deleted." -f $sessionsFound.Count)
        throw "Existing user sessions prevent replacement. $sessionSummary. AVD Manager should continue the drain workflow and only restart this runbook when zero sessions remain."
    }

    Write-Log -Level 'SUCCESS' -Component 'AVD' -Message 'Final safety check passed: all existing hosts are drained and zero user sessions remain.'

    foreach ($state in $sessionHostStates) {
        $sessionHostName = $state.SessionHostName
        $sessionHostFullName = $state.SessionHostFullName
        $vmName = $state.VmName

        Write-Log "Processing existing session host '$sessionHostFullName' as '$sessionHostName' (VM: '$vmName')..."

        try {
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
        [string]$SubnetId,
        [pscredential]$LocalAdminCredential
    )

    if ([string]::IsNullOrWhiteSpace($SubnetId)) {
        throw "SubnetId cannot be empty when creating '$VmName'."
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
        -SubnetId $SubnetId `
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
    $joinParameters = @{
        ResourceGroupName = $SessionHostResourceGroupName
        VMName            = $VmName
        Name              = 'joindomain'
        DomainName        = $DomainFqdn
        Credential        = $DomainJoinCredential
        JoinOption        = 3
        Restart           = $true
        ForceRerun        = (Get-Date).Ticks
    }

    if (-not [string]::IsNullOrWhiteSpace($DomainOuPath)) {
        $joinParameters['OUPath'] = $DomainOuPath
    }

    Set-AzVMADDomainExtension @joinParameters | Out-Null

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

function Get-ScalingPlansAttachedToHostPool {
    param(
        [string]$HostPoolArmPath
    )

    $attachedScalingPlans = @()

    Write-Log -Level 'INFO' -Component 'SCALING' -Message "Checking for scaling plans attached to host pool '$HostPoolName'..."

    $scalingPlanResources = Get-AzResource `
        -ResourceType 'Microsoft.DesktopVirtualization/scalingPlans' `
        -ErrorAction SilentlyContinue

    if (-not $scalingPlanResources) {
        Write-Log -Level 'INFO' -Component 'SCALING' -Message 'No scaling plans were found in the current subscription.'
        return @()
    }

    foreach ($resource in $scalingPlanResources) {
        try {
            $plan = Get-AzWvdScalingPlan `
                -ResourceGroupName $resource.ResourceGroupName `
                -Name $resource.Name `
                -ErrorAction Stop

            $matchingReference = @($plan.HostPoolReference | Where-Object {
                $_.HostPoolArmPath -eq $HostPoolArmPath
            })

            foreach ($reference in $matchingReference) {
                $attachedScalingPlans += [pscustomobject]@{
                    Name              = $plan.Name
                    ResourceGroupName = $resource.ResourceGroupName
                    HostPoolArmPath   = $reference.HostPoolArmPath
                    OriginalEnabled   = [bool]$reference.ScalingPlanEnabled
                }
            }
        }
        catch {
            Write-Log -Level 'WARN' -Component 'SCALING' -Message ("Unable to inspect scaling plan '{0}' in resource group '{1}': {2}" -f $resource.Name, $resource.ResourceGroupName, $_.Exception.Message)
        }
    }

    return @($attachedScalingPlans)
}

function Set-ScalingPlanHostPoolReferenceState {
    param(
        [string]$ScalingPlanName,
        [string]$ScalingPlanResourceGroupName,
        [string]$HostPoolArmPath,
        [bool]$Enabled
    )

    $plan = Get-AzWvdScalingPlan `
        -ResourceGroupName $ScalingPlanResourceGroupName `
        -Name $ScalingPlanName `
        -ErrorAction Stop

    $references = @($plan.HostPoolReference)
    if (-not $references -or $references.Count -eq 0) {
        throw "Scaling plan '$ScalingPlanName' has no host pool references."
    }

    $updatedReferences = @()
    $foundReference = $false

    foreach ($reference in $references) {
        $referenceEnabled = [bool]$reference.ScalingPlanEnabled
        if ($reference.HostPoolArmPath -eq $HostPoolArmPath) {
            $referenceEnabled = $Enabled
            $foundReference = $true
        }

        $updatedReferences += New-AzWvdHostPoolReference `
            -HostPoolArmPath $reference.HostPoolArmPath `
            -ScalingPlanEnabled:$referenceEnabled
    }

    if (-not $foundReference) {
        throw "Host pool '$HostPoolArmPath' is no longer referenced by scaling plan '$ScalingPlanName'."
    }

    Update-AzWvdScalingPlan `
        -ResourceGroupName $ScalingPlanResourceGroupName `
        -Name $ScalingPlanName `
        -HostPoolReference $updatedReferences `
        -ErrorAction Stop | Out-Null
}

function Disable-EnabledScalingPlansForDeployment {
    param(
        [string]$HostPoolArmPath,
        [ref]$ScalingPlansToReenable
    )

    $ScalingPlansToReenable.Value = @()

    if (-not [bool]$TemporarilyDisableScalingDuringDeployment) {
        Write-Log -Level 'INFO' -Component 'SCALING' -Message 'Temporary scaling-plan disable is disabled by configuration.'
        return
    }

    $attachedScalingPlans = @(Get-ScalingPlansAttachedToHostPool -HostPoolArmPath $HostPoolArmPath)

    if (-not $attachedScalingPlans -or $attachedScalingPlans.Count -eq 0) {
        Write-Log -Level 'INFO' -Component 'SCALING' -Message 'No scaling plan is attached to the selected host pool.'
        return
    }

    foreach ($attachedScalingPlan in $attachedScalingPlans) {
        if (-not $attachedScalingPlan.OriginalEnabled) {
            Write-Log -Level 'INFO' -Component 'SCALING' -Message ("Scaling plan '{0}' is attached but already disabled for this host pool. Leaving it disabled." -f $attachedScalingPlan.Name)
            continue
        }

        Write-Log -Level 'INFO' -Component 'SCALING' -Message ("Scaling plan '{0}' is enabled for this host pool. Temporarily disabling it before deployment." -f $attachedScalingPlan.Name)

        Set-ScalingPlanHostPoolReferenceState `
            -ScalingPlanName $attachedScalingPlan.Name `
            -ScalingPlanResourceGroupName $attachedScalingPlan.ResourceGroupName `
            -HostPoolArmPath $HostPoolArmPath `
            -Enabled $false

        $ScalingPlansToReenable.Value += $attachedScalingPlan
    }
}

function Restore-ScalingPlansAfterDeployment {
    param(
        [string]$HostPoolArmPath,
        [object[]]$ScalingPlansToReenable
    )

    if (-not [bool]$TemporarilyDisableScalingDuringDeployment) {
        return
    }

    if (-not $ScalingPlansToReenable -or $ScalingPlansToReenable.Count -eq 0) {
        Write-Log -Level 'INFO' -Component 'SCALING' -Message 'No scaling plans were disabled by this run, so none will be re-enabled.'
        return
    }

    Write-StepBanner -Message 'RESTORE SCALING PLAN'

    foreach ($scalingPlan in $ScalingPlansToReenable) {
        Write-Log -Level 'INFO' -Component 'SCALING' -Message ("Re-enabling scaling plan '{0}' for host pool '{1}'." -f $scalingPlan.Name, $HostPoolName)

        Set-ScalingPlanHostPoolReferenceState `
            -ScalingPlanName $scalingPlan.Name `
            -ScalingPlanResourceGroupName $scalingPlan.ResourceGroupName `
            -HostPoolArmPath $HostPoolArmPath `
            -Enabled $true
    }
}

$hostPoolArmPath = $null
$scalingPlansToReenable = @()
$scalingPlansRestored = $false

try {
    Connect-RunbookAz
    Test-DeploymentInputs
    Test-JoinConfiguration

    $preflight = Test-DeploymentEnvironment
    $hostPoolArmPath = $preflight.HostPool.Id
    $imageSelection = $preflight.ImageSelection
    $imageVersionId = $imageSelection.Id
    $subnetId = $preflight.SubnetId

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

    if ([bool]$OverwriteExisting) {
        $targetVmNames = @(Get-NextVmNamesForHostPoolCount -Prefix $VmNamePrefix -Count $SessionHostCount -ExistingHostCount 0)
    }
    else {
        $targetVmNames = @(Get-NextVmNamesForHostPoolCount -Prefix $VmNamePrefix -Count $SessionHostCount -ExistingHostCount $existingHostCount)
    }

    Test-TargetVmNames -VmNames $targetVmNames

    # Generate the registration token before deleting anything so a missing permission
    # or invalid host-pool configuration fails without causing avoidable downtime.
    $registrationToken = $null
    Get-HostPoolRegistrationToken -RegistrationToken ([ref]$registrationToken)

    Write-StepBanner -Message 'DEPLOYMENT PLAN'
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Subscription        : {0}" -f $SubscriptionId)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Location            : {0}" -f $Location)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Host pool           : {0}" -f $HostPoolName)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Host pool RG        : {0}" -f $HostPoolResourceGroupName)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Session host RG     : {0}" -f $SessionHostResourceGroupName)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("VM prefix           : {0}" -f $VmNamePrefix)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Requested hosts     : {0}" -f $SessionHostCount)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("VM size             : {0}" -f $VmSize)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Gallery             : {0}/{1}" -f $GalleryResourceGroupName, $GalleryName)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Image definition    : {0}" -f $GalleryImageDefinitionName)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Image version       : {0} (resolved to {1})" -f $GalleryImageVersion, $imageSelection.Version)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Network             : {0}/{1}/{2}" -f $VirtualNetworkResourceGroupName, $VirtualNetworkName, $SubnetName)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("JoinType            : {0}" -f $JoinType)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Enable Intune       : {0}" -f ([bool]$EnableIntuneEnrollment))
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("OverwriteExisting   : {0}" -f ([bool]$OverwriteExisting))
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Disable scaling temp: {0}" -f ([bool]$TemporarilyDisableScalingDuringDeployment))
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Existing host count : {0}" -f $existingHostCount)
    Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Target VM names     : {0}" -f ($targetVmNames -join ', '))

    if ($existingHostCount -gt 0) {
        Write-Log -Level 'INFO' -Component 'PLAN' -Message ("Existing VM names   : {0}" -f ($existingHostVmNames -join ', '))
    }

    Disable-EnabledScalingPlansForDeployment `
        -HostPoolArmPath $hostPoolArmPath `
        -ScalingPlansToReenable ([ref]$scalingPlansToReenable)

    if ([bool]$OverwriteExisting -and $existingHostCount -gt 0) {
        Write-StepBanner -Message 'DELETE EXISTING HOSTS'
        Write-Log -Level 'WARN' -Component 'PLAN' -Message 'OverwriteExisting is True. The runbook will now repeat the drain/zero-session fail-closed safety gate before deleting any existing host.'
        Invoke-DrainAndDeleteExistingHosts -DomainJoinCredential $domainJoinCredential
    }
    elseif (-not [bool]$OverwriteExisting) {
        Write-Log -Level 'INFO' -Component 'PLAN' -Message 'OverwriteExisting is False. Existing hosts will be retained.'
    }

    Write-StepBanner -Message 'IMAGE SELECTION'
    Write-Log -Level 'SUCCESS' -Component 'IMAGE' -Message ("Using gallery image '{0}' version '{1}'." -f $GalleryImageDefinitionName, $imageSelection.Version)
    Write-Log -Level 'INFO' -Component 'IMAGE' -Message ("Gallery image version resource id: {0}" -f $imageVersionId)

    for ($i = 0; $i -lt $targetVmNames.Count; $i++) {
        $vmName = $targetVmNames[$i]
        $deployOrdinal = $i + 1

        Write-StepBanner -Message ("DEPLOYMENT {0} OF {1}" -f $deployOrdinal, $targetVmNames.Count)
        Write-Log -Level 'INFO' -Component 'DEPLOY' -Message ("Starting deployment for VM '{0}'" -f $vmName)

        New-SessionHostVm `
            -VmName $vmName `
            -ImageVersionId $imageVersionId `
            -SubnetId $subnetId `
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

    Restore-ScalingPlansAfterDeployment `
        -HostPoolArmPath $hostPoolArmPath `
        -ScalingPlansToReenable $scalingPlansToReenable
    $scalingPlansRestored = $true

    Write-StepBanner -Message 'COMPLETE'
    Write-Log -Level 'SUCCESS' -Component 'RUNBOOK' -Message "Runbook completed successfully."
}
catch {
    $originalError = $_

    if ($hostPoolArmPath -and -not $scalingPlansRestored) {
        try {
            Write-Log -Level 'WARN' -Component 'SCALING' -Message 'The deployment did not complete. Attempting to restore any scaling plans disabled by this run...'
            Restore-ScalingPlansAfterDeployment `
                -HostPoolArmPath $hostPoolArmPath `
                -ScalingPlansToReenable $scalingPlansToReenable
            $scalingPlansRestored = $true
        }
        catch {
            Write-Log -Level 'ERROR' -Component 'SCALING' -Message ("Scaling plan recovery also failed: {0}" -f $_.Exception.Message)
        }
    }

    Throw-RunbookError -Step "RUNBOOK" -ErrorRecord $originalError
}
