<#
.SYNOPSIS
    Stage 2 AVD Hybrid deployment runbook for Hyper-V session hosts.

    Version 15 fixes Azure Arc connection-state detection by parsing JSON where available
    and recognising the current "Agent Status : Connected" output.

.DESCRIPTION
    Deploys Azure Virtual Desktop Hybrid session hosts onto Hyper-V using the VHDX template
    produced by Stage 1: AVDHybridImageSync.

    This version supports:
        - AVD host pool in one Azure subscription.
        - Azure Arc-enabled servers in a different Azure subscription.
        - Hyper-V VM creation from the synced VHDX template.
        - AD DS join.
        - Azure Arc onboarding.
        - AVD Hybrid Arc extension deployment.

.PARAMETER VmNamePrefix
    VM name prefix, for example: hybavd

.PARAMETER SessionHostCount
    Number of session hosts to deploy.

.PARAMETER OverwriteExisting
    If true, removes existing matching AVD session host, Arc resource, Hyper-V VM and AD computer object before redeploying.

.NOTES
    Runbook type:
        PowerShell 5.1

    Must run on:
        Azure Automation Hybrid Runbook Worker.

    Required Automation Variables:
        AVDHybrid-CurrentTemplatePath
        AVDHybrid-CurrentGalleryVersion

    Required Automation Account modules:
        Az.Accounts
        Az.KeyVault
        Az.DesktopVirtualization
        Az.ConnectedMachine
        Az.Resources

    Required on the Hyper-V management context:
        Hyper-V PowerShell module.
        WinRM configured if the Hybrid Worker is not the Hyper-V host itself.
        The Hybrid Worker identity must be able to manage the Hyper-V host.

    Required inside the guest:
        Internet / required endpoint access to Azure Arc and Azure Virtual Desktop URLs.
        Local administrator credential injected through unattend.xml / image.

    IMPORTANT:
        Test with SessionHostCount = 1 first.

    VERSION 13 CHANGES:
        - Waits for the domain-join reboot to genuinely start and complete.
        - Requires consecutive healthy PowerShell Direct checks after domain join.
        - Confirms domain membership, DNS and network readiness before Azure Arc installation.
        - Adds a post-domain-join settling period.
        - Makes Azure Arc installation idempotent and retryable after interrupted guest sessions.
        - Detects an already-installed or already-connected Azure Connected Machine Agent.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$VmNamePrefix,

    [Parameter(Mandatory = $true)]
    [int]$SessionHostCount,

    [Parameter(Mandatory = $false)]
    [bool]$OverwriteExisting = $false
)

################################################################################################################
# CONFIGURATION
################################################################################################################

# Tenant
$TenantId                              = "X-X-X-X"

# Subscriptions
# AVD subscription = where the host pool lives.
# Arc subscription = where the Azure Arc-enabled server resources live.
$AvdSubscriptionId                     = "X-X-X-X"
$ArcSubscriptionId                     = "X-X-X-X"

# AVD
$HostPoolResourceGroupName             = "rg-avd-hosts-uks"
$HostPoolName                          = "vdpool-avd-prod-uks-hybrid"
$RegistrationTokenHours                = 24
$RegistrationTimeoutMinutes            = 30
$RegistrationPollSeconds               = 30

# Azure Arc
$ArcResourceGroupName                  = "rg-avd-hosts-uks"
$ArcLocation                           = "uksouth"
$ArcCloud                              = "AzureCloud"

# Stage 1 Automation Variables
$CurrentTemplatePathVariableName       = "AVDHybrid-CurrentTemplatePath"
$CurrentGalleryVersionVariableName     = "AVDHybrid-CurrentGalleryVersion"

# Key Vault
# The Key Vault can be in either subscription. Set the subscription it lives in below.
$KeyVaultSubscriptionId                = $AvdSubscriptionId
$KeyVaultName                          = "kv-phxr-avd-uks-07"

# Guest local administrator
# These credentials are injected into unattend.xml and then used by PowerShell Direct.
$LocalAdminUsernameSecretName           = "adm-local-upn"
$LocalAdminPasswordSecretName           = "adm-local-pw"

# AD DS join
$DomainFqdn                            = "domain.co.uk"
$DomainOuPath                          = ""
$DomainJoinUsernameSecretName           = "domainjoin-upn"
$DomainJoinPasswordSecretName           = "domainjoin-pw"

# Azure Arc onboarding service principal
# Store these in Key Vault. The service principal should have Azure Connected Machine Onboarding
# or equivalent rights at the target Arc scope.
$ArcServicePrincipalIdSecretName        = "arc-sp-appid"
$ArcServicePrincipalSecretSecretName    = "arc-sp-secret"

# Hyper-V host / VM configuration
# If the Hybrid Worker is the Hyper-V host, set ExecuteHyperVCommandsLocally = $true.
# If not, the Hybrid Worker must be able to remote to the Hyper-V host using WinRM.
$ExecuteHyperVCommandsLocally           = $false
$HyperVHostName                         = "avdhyperv.phoenixdemo.co.uk"
$HyperVVmRootPath                       = "E:\Hyper-V\AVDHybrid"
$HyperVSwitchName                       = "AVDHybridNAT"

$VmGeneration                           = 2
$ProcessorCount                         = 2
$MemoryStartupBytes                     = 8GB
$UseDynamicMemory                       = $true
$MemoryMinimumBytes                     = 4GB
$MemoryMaximumBytes                     = 12GB

# OS / first boot
$InjectUnattendXml                      = $true
$TimeZone                               = "GMT Standard Time"
$WaitForPowerShellDirectTimeoutMinutes  = 30
$WaitForPowerShellDirectPollSeconds     = 20
$DomainJoinTimeoutMinutes               = 30
$DomainJoinPollSeconds                  = 20
$PostDomainJoinStableChecks             = 3
$PostDomainJoinStablePollSeconds         = 20
$PostDomainJoinSettleSeconds             = 90


# Azure Arc install inside guest
$ArcAgentDownloadUrl                    = "https://aka.ms/AzureConnectedMachineAgent"
$ArcInstallFolder                       = "C:\AVDHybrid\Arc"
$ArcConnectTimeoutMinutes               = 20
$ArcConnectPollSeconds                  = 30
$ArcInstallRetryCount                    = 5
$ArcInstallRetryDelaySeconds             = 45


# Cleanup / behaviour
$DrainModeBeforeDelete                  = $false
$ForceLogoffUsers                       = $false
$RemoveAdComputerOnOverwrite            = $true
$RemoveArcResourceOnOverwrite           = $true
$DeleteVmFilesOnOverwrite               = $true
$VmCreationThrottleSeconds              = 10

# Tags for Arc resource. Keep values simple.
$ArcTags = @{
    Workload       = "AVD"
    DeploymentMode = "Hybrid"
    ManagedBy      = "AzureAutomation"
    Source         = "AVDHybridImageSync"
}

$ErrorActionPreference = "Stop"
$ConfirmPreference = "None"


################################################################################################################
# MODULES
################################################################################################################

Import-Module Az.Accounts               -ErrorAction Stop
Import-Module Az.KeyVault               -ErrorAction Stop
Import-Module Az.Resources              -ErrorAction Stop
Import-Module Az.DesktopVirtualization  -ErrorAction Stop
Import-Module Az.ConnectedMachine       -ErrorAction Stop


################################################################################################################
# LOGGING / ERROR HANDLING
################################################################################################################

function Write-Log {
    param(
        [Parameter(Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO",

        [Parameter(Position = 2)]
        [string]$Component = "RUNBOOK"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output ("[{0}] [{1}] [{2}] {3}" -f $timestamp, $Level, $Component, $Message)
}

function Write-StepBanner {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Log -Level "INFO" -Component "STEP" -Message ("================ {0} ================" -f $Message)
}

function Throw-RunbookError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Step,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-Log -Level "ERROR" -Component $Step -Message $ErrorRecord.Exception.Message

    if ($ErrorRecord.InvocationInfo.Line) {
        Write-Log -Level "ERROR" -Component $Step -Message ("Line: {0}" -f $ErrorRecord.InvocationInfo.Line)
    }

    if ($ErrorRecord.ScriptStackTrace) {
        Write-Log -Level "ERROR" -Component $Step -Message ("Stack: {0}" -f $ErrorRecord.ScriptStackTrace)
    }

    throw $ErrorRecord
}


################################################################################################################
# AZURE CONTEXT HELPERS
################################################################################################################

function Connect-RunbookAz {
    try {
        Write-StepBanner -Message "AUTHENTICATION"
        Write-Log -Level "INFO" -Component "AUTH" -Message "Authenticating with managed identity..."

        Disable-AzContextAutosave -Scope Process | Out-Null
        Connect-AzAccount -Identity -Tenant $TenantId | Out-Null

        Set-AvdContext

        Write-Log -Level "SUCCESS" -Component "AUTH" -Message "Authenticated and AVD subscription context set."
    }
    catch {
        Throw-RunbookError -Step "AUTHENTICATION" -ErrorRecord $_
    }
}

function Set-AvdContext {
    if ([string]::IsNullOrWhiteSpace($AvdSubscriptionId) -or $AvdSubscriptionId -eq "00000000-0000-0000-0000-000000000000") {
        throw "AvdSubscriptionId has not been configured."
    }

    Set-AzContext -SubscriptionId $AvdSubscriptionId -Tenant $TenantId | Out-Null
}

function Set-ArcContext {
    if ([string]::IsNullOrWhiteSpace($ArcSubscriptionId) -or $ArcSubscriptionId -eq "00000000-0000-0000-0000-000000000000") {
        throw "ArcSubscriptionId has not been configured."
    }

    Set-AzContext -SubscriptionId $ArcSubscriptionId -Tenant $TenantId | Out-Null
}

function Set-KeyVaultContext {
    if ([string]::IsNullOrWhiteSpace($KeyVaultSubscriptionId) -or $KeyVaultSubscriptionId -eq "00000000-0000-0000-0000-000000000000") {
        throw "KeyVaultSubscriptionId has not been configured."
    }

    Set-AzContext -SubscriptionId $KeyVaultSubscriptionId -Tenant $TenantId | Out-Null
}


################################################################################################################
# GENERAL HELPERS
################################################################################################################

function Get-PlainSecretOrThrow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VaultName,

        [Parameter(Mandatory = $true)]
        [string]$SecretName
    )

    try {
        Set-KeyVaultContext

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
        [Parameter(Mandatory = $true)]
        [string]$VaultName,

        [Parameter(Mandatory = $true)]
        [string]$UsernameSecretName,

        [Parameter(Mandatory = $true)]
        [string]$PasswordSecretName
    )

    $username = Get-PlainSecretOrThrow -VaultName $VaultName -SecretName $UsernameSecretName
    $password = Get-PlainSecretOrThrow -VaultName $VaultName -SecretName $PasswordSecretName

    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    return [pscredential]::new($username, $securePassword)
}

function Get-PlainTextFromSecureString {
    param(
        [Parameter(Mandatory = $true)]
        [securestring]$SecureString
    )

    $bstr = [IntPtr]::Zero

    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function New-LocalVmCredentialForPowerShellDirect {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [pscredential]$Credential
    )

    # PowerShell Direct is more reliable when the username is explicitly scoped
    # to the guest VM's local SAM, for example: VMNAME\localadmin.
    $rawUsername = $Credential.UserName

    if ($rawUsername -match "\\") {
        $localUsername = ($rawUsername -split "\\")[-1]
    }
    elseif ($rawUsername -match "@") {
        $localUsername = ($rawUsername -split "@")[0]
    }
    else {
        $localUsername = $rawUsername
    }

    $scopedUsername = "{0}\{1}" -f $VmName, $localUsername

    return [pscredential]::new($scopedUsername, $Credential.Password)
}

function Get-TemplatePathFromAutomationVariable {
    $templatePath = Get-AutomationVariable -Name $CurrentTemplatePathVariableName -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($templatePath)) {
        throw "Automation Variable '$CurrentTemplatePathVariableName' is empty. Stage 1 must complete first."
    }

    return $templatePath
}

function Get-CurrentGalleryVersionFromAutomationVariable {
    try {
        return Get-AutomationVariable -Name $CurrentGalleryVersionVariableName -ErrorAction SilentlyContinue
    }
    catch {
        return $null
    }
}

function Invoke-HyperVHostCommand {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList = @()
    )

    $localComputer = $env:COMPUTERNAME
    $hyperVShortName = ($HyperVHostName -split "\.")[0]

    if ($ExecuteHyperVCommandsLocally -or ($localComputer -ieq $hyperVShortName)) {
        & $ScriptBlock @ArgumentList
    }
    else {
        Invoke-Command -ComputerName $HyperVHostName -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    }
}

function Get-SessionHostShortName {
    param(
        [string]$SessionHostName
    )

    if ([string]::IsNullOrWhiteSpace($SessionHostName)) {
        return $null
    }

    $leaf = ($SessionHostName -split "/")[-1]
    return ($leaf -split "\.")[0]
}

function Get-NextVmNamesForHostPoolCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [int]$Count,

        [Parameter(Mandatory = $true)]
        [int]$ExistingHostCount
    )

    $newNames = @()

    for ($i = 1; $i -le $Count; $i++) {
        $newNames += ("{0}-{1:D2}" -f $Prefix, ($ExistingHostCount + $i))
    }

    return $newNames
}


################################################################################################################
# AVD HELPERS
################################################################################################################

function Get-ExistingSessionHostVmNames {
    Set-AvdContext

    $sessionHosts = Get-AzWvdSessionHost `
        -ResourceGroupName $HostPoolResourceGroupName `
        -HostPoolName $HostPoolName `
        -ErrorAction SilentlyContinue

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

function Get-HostPoolRegistrationToken {
    param(
        [Parameter(Mandatory = $true)]
        [ref]$RegistrationToken
    )

    Set-AvdContext

    $RegistrationToken.Value = $null

    $expiration = (Get-Date).ToUniversalTime().AddHours($RegistrationTokenHours).ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")

    Write-StepBanner -Message "REGISTRATION TOKEN"
    Write-Log -Level "INFO" -Component "AVD" -Message "Generating AVD registration token valid for $RegistrationTokenHours hour(s)..."

    $token = New-AzWvdRegistrationInfo `
        -ResourceGroupName $HostPoolResourceGroupName `
        -HostPoolName $HostPoolName `
        -ExpirationTime $expiration

    if (-not $token.Token) {
        throw "Host pool registration token was not returned."
    }

    $RegistrationToken.Value = $token.Token
}

function Wait-ForSessionHostRegistration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExpectedVmName,

        [int]$TimeoutMinutes = 30,

        [int]$PollSeconds = 30,

        [Parameter(Mandatory = $true)]
        [ref]$Registered
    )

    Set-AvdContext

    $Registered.Value = $false
    $maxChecks = [math]::Ceiling(($TimeoutMinutes * 60) / $PollSeconds)

    for ($i = 1; $i -le $maxChecks; $i++) {
        $hosts = Get-AzWvdSessionHost `
            -ResourceGroupName $HostPoolResourceGroupName `
            -HostPoolName $HostPoolName `
            -ErrorAction SilentlyContinue

        $match = $hosts | Where-Object {
            $short = Get-SessionHostShortName -SessionHostName $_.Name
            $short -ieq $ExpectedVmName
        } | Select-Object -First 1

        if ($match) {
            Write-Log -Level "SUCCESS" -Component "AVD" -Message "Session host '$ExpectedVmName' is registered in host pool '$HostPoolName'."
            $Registered.Value = $true
            return
        }

        Write-Log -Level "INFO" -Component "AVD" -Message "Waiting for session host '$ExpectedVmName' to register. Check $i of $maxChecks..."
        Start-Sleep -Seconds $PollSeconds
    }
}

function Remove-SessionHostIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    Set-AvdContext

    $hosts = Get-AzWvdSessionHost `
        -ResourceGroupName $HostPoolResourceGroupName `
        -HostPoolName $HostPoolName `
        -ErrorAction SilentlyContinue

    if (-not $hosts) {
        return
    }

    $matches = @(
        $hosts | Where-Object {
            $short = Get-SessionHostShortName -SessionHostName $_.Name
            $short -ieq $VmName
        }
    )

    foreach ($match in $matches) {
        $sessionHostName = ($match.Name -split "/")[-1]

        Write-Log -Level "INFO" -Component "AVD" -Message "Removing existing AVD session host '$sessionHostName'..."

        if ($DrainModeBeforeDelete) {
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
                Remove-AzWvdUserSession `
                    -ResourceGroupName $HostPoolResourceGroupName `
                    -HostPoolName $HostPoolName `
                    -SessionHostName $sessionHostName `
                    -Id $userSession.Id `
                    -Force `
                    -Confirm:$false | Out-Null
            }
        }

        Remove-AzWvdSessionHost `
            -ResourceGroupName $HostPoolResourceGroupName `
            -HostPoolName $HostPoolName `
            -Name $sessionHostName `
            -Force `
            -Confirm:$false | Out-Null
    }
}


################################################################################################################
# AD CLEANUP
################################################################################################################

function Remove-AdComputerObjectIfRequired {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [pscredential]$DomainJoinCredential
    )

    if (-not $RemoveAdComputerOnOverwrite) {
        return
    }

    Write-Log -Level "INFO" -Component "ADDS" -Message "Attempting to remove AD computer object for '$VmName'..."

    $plainPassword = $null
    $bstr = [IntPtr]::Zero

    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($DomainJoinCredential.Password)
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

        $domainDn = (($DomainFqdn -split "\.") | ForEach-Object { "DC=$_" }) -join ","

        Add-Type -AssemblyName System.DirectoryServices

        $root = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$domainDn", $DomainJoinCredential.UserName, $plainPassword)
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($root)
        $searcher.Filter = "(&(objectCategory=computer)(sAMAccountName=$VmName`$))"
        $searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree

        $result = $searcher.FindOne()

        if ($null -eq $result) {
            Write-Log -Level "INFO" -Component "ADDS" -Message "No AD computer object found for '$VmName'."
            return
        }

        $computerObject = $result.GetDirectoryEntry()
        $distinguishedName = $computerObject.Properties["distinguishedName"][0]

        $computerObject.DeleteTree()
        $computerObject.CommitChanges()

        Write-Log -Level "SUCCESS" -Component "ADDS" -Message "Removed AD computer object '$distinguishedName'."
    }
    catch {
        Write-Log -Level "WARN" -Component "ADDS" -Message "Could not remove AD computer object for '$VmName'. Error: $($_.Exception.Message)"
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        $plainPassword = $null
    }
}


################################################################################################################
# ARC HELPERS
################################################################################################################

function Remove-ArcMachineIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    if (-not $RemoveArcResourceOnOverwrite) {
        return
    }

    Set-ArcContext

    $arcMachine = Get-AzResource `
        -ResourceGroupName $ArcResourceGroupName `
        -ResourceType "Microsoft.HybridCompute/machines" `
        -Name $VmName `
        -ErrorAction SilentlyContinue

    if (-not $arcMachine) {
        Write-Log -Level "INFO" -Component "ARC" -Message "No Arc machine resource found for '$VmName'."
        return
    }

    Write-Log -Level "INFO" -Component "ARC" -Message "Removing Arc machine resource '$VmName'..."

    Remove-AzResource `
        -ResourceId $arcMachine.ResourceId `
        -Force `
        -ErrorAction Stop | Out-Null

    Write-Log -Level "SUCCESS" -Component "ARC" -Message "Removed Arc machine resource '$VmName'."
}

function Wait-ForArcMachine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [ref]$Found
    )

    Set-ArcContext

    $Found.Value = $false
    $maxChecks = [math]::Ceiling(($ArcConnectTimeoutMinutes * 60) / $ArcConnectPollSeconds)

    for ($i = 1; $i -le $maxChecks; $i++) {
        $arcMachine = Get-AzResource `
            -ResourceGroupName $ArcResourceGroupName `
            -ResourceType "Microsoft.HybridCompute/machines" `
            -Name $VmName `
            -ErrorAction SilentlyContinue

        if ($arcMachine) {
            Write-Log -Level "SUCCESS" -Component "ARC" -Message "Arc machine '$VmName' found in resource group '$ArcResourceGroupName'."
            $Found.Value = $true
            return
        }

        Write-Log -Level "INFO" -Component "ARC" -Message "Waiting for Arc machine '$VmName'. Check $i of $maxChecks..."
        Start-Sleep -Seconds $ArcConnectPollSeconds
    }
}

function Install-AvdArcExtension {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$RegistrationToken
    )

    Set-ArcContext

    Write-Log -Level "INFO" -Component "AVD" -Message "Deploying Azure Virtual Desktop Arc extension to '$VmName'..."

    $settings = @{
        isCloudDevice = $false
    }

    $protectedSettings = @{
        registrationToken = $RegistrationToken
    }

    $existingExtension = Get-AzConnectedMachineExtension `
        -ResourceGroupName $ArcResourceGroupName `
        -MachineName $VmName `
        -Name "Microsoft.AzureVirtualDesktop.CloudDeviceExtension" `
        -ErrorAction SilentlyContinue

    if ($existingExtension) {
        Write-Log -Level "WARN" -Component "AVD" -Message "Existing AVD Arc extension found on '$VmName'. Removing it before redeploying."

        Remove-AzConnectedMachineExtension `
            -ResourceGroupName $ArcResourceGroupName `
            -MachineName $VmName `
            -Name "Microsoft.AzureVirtualDesktop.CloudDeviceExtension" `
            -Force `
            -ErrorAction SilentlyContinue | Out-Null
    }

    New-AzConnectedMachineExtension `
        -Name "Microsoft.AzureVirtualDesktop.CloudDeviceExtension" `
        -ResourceGroupName $ArcResourceGroupName `
        -MachineName $VmName `
        -Location $ArcLocation `
        -Publisher "Microsoft.AzureVirtualDesktop" `
        -ExtensionType "CloudDeviceExtension" `
        -Setting $settings `
        -ProtectedSetting $protectedSettings `
        -ErrorAction Stop | Out-Null

    Write-Log -Level "SUCCESS" -Component "AVD" -Message "AVD Arc extension deployment command submitted for '$VmName'."
}


################################################################################################################
# HYPER-V / GUEST HELPERS
################################################################################################################

function Remove-HyperVVmIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    Write-Log -Level "INFO" -Component "HYPERV" -Message "Checking for existing Hyper-V VM '$VmName'..."

    $scriptBlock = {
        param(
            [string]$VmName,
            [bool]$DeleteFiles
        )

        Import-Module Hyper-V -ErrorAction Stop

        $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue

        if (-not $vm) {
            Write-Output "No Hyper-V VM found for '$VmName'."
            return
        }

        $vmPath = $vm.Path

        if ($vm.State -ne "Off") {
            Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
        }

        Remove-VM -Name $VmName -Force

        Write-Output "Removed Hyper-V VM '$VmName'."

        if ($DeleteFiles -and $vmPath -and (Test-Path $vmPath)) {
            Remove-Item -Path $vmPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Output "Removed VM files at '$vmPath'."
        }
    }

    $output = Invoke-HyperVHostCommand -ScriptBlock $scriptBlock -ArgumentList @($VmName, $DeleteVmFilesOnOverwrite)
    $output | ForEach-Object { Write-Log -Level "INFO" -Component "HYPERV" -Message $_ }
}

function New-HyperVSessionHostVm {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$TemplatePath,

        [Parameter(Mandatory = $true)]
        [pscredential]$GuestLocalAdminCredential
    )

    Write-Log -Level "INFO" -Component "HYPERV" -Message "Creating Hyper-V VM '$VmName' from template '$TemplatePath'..."

    $localAdminPlainPassword = Get-PlainTextFromSecureString -SecureString $GuestLocalAdminCredential.Password

    $scriptBlock = {
        param(
            [string]$VmName,
            [string]$TemplatePath,
            [string]$VmRootPath,
            [string]$SwitchName,
            [int]$Generation,
            [int64]$MemoryStartupBytes,
            [bool]$UseDynamicMemory,
            [int64]$MemoryMinimumBytes,
            [int64]$MemoryMaximumBytes,
            [int]$ProcessorCount,
            [bool]$InjectUnattend,
            [string]$LocalAdminUsername,
            [string]$LocalAdminPlainPassword,
            [string]$TimeZone
        )

        Import-Module Hyper-V -ErrorAction Stop

        function ConvertTo-XmlEscapedTextLocal {
            param([AllowNull()][string]$Value)

            if ($null -eq $Value) {
                return ""
            }

            return [System.Security.SecurityElement]::Escape($Value)
        }

        function ConvertTo-PowerShellSingleQuotedStringLocal {
            param([AllowNull()][string]$Value)

            if ($null -eq $Value) {
                return "''"
            }

            return "'" + ($Value -replace "'", "''") + "'"
        }

        function Get-FreeDriveLetterLocal {
            $usedLetters = Get-Volume | Where-Object DriveLetter | Select-Object -ExpandProperty DriveLetter
            $candidateLetters = "Z","Y","X","W","V","U","T","S","R","Q","P","O","N","M","L","K","J","I","H","G","F","E","D"

            foreach ($letter in $candidateLetters) {
                if ($usedLetters -notcontains $letter) {
                    return $letter
                }
            }

            throw "No free drive letter available for temporary VHD mount."
        }

        if (-not (Test-Path $TemplatePath)) {
            throw "Template path does not exist or is not accessible from Hyper-V host: $TemplatePath"
        }

        if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
            throw "Hyper-V VM '$VmName' already exists."
        }

        if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
            throw "Hyper-V switch '$SwitchName' was not found."
        }

        $vmFolder = Join-Path $VmRootPath $VmName
        $vhdFolder = Join-Path $vmFolder "Virtual Hard Disks"
        $destVhdPath = Join-Path $vhdFolder "$VmName.vhdx"

        New-Item -Path $vhdFolder -ItemType Directory -Force | Out-Null

        Write-Output "Copying template VHDX to '$destVhdPath'..."
        Copy-Item -Path $TemplatePath -Destination $destVhdPath -Force

        if ($InjectUnattend) {
            Write-Output "Injecting unattend.xml into '$destVhdPath'..."

            $mounted = $null
            $diskNumber = $null
            $temporaryAccessPaths = @()

            try {
                $mounted = Mount-VHD -Path $destVhdPath -Passthru -ErrorAction Stop
                Start-Sleep -Seconds 5

                $disk = @($mounted | Get-Disk -ErrorAction Stop | Select-Object -First 1)

                if (-not $disk) {
                    throw "Unable to resolve mounted VHDX to a disk."
                }

                $diskNumber = [int]$disk.Number
                Write-Output "Mounted VHDX as disk number $diskNumber."

                # Bring the mounted disk online/read-write if Windows presents it offline.
                try {
                    Set-Disk -Number $diskNumber -IsOffline $false -ErrorAction SilentlyContinue
                    Set-Disk -Number $diskNumber -IsReadOnly $false -ErrorAction SilentlyContinue
                }
                catch {
                    Write-Output "Disk online/read-write adjustment warning: $($_.Exception.Message)"
                }

                $partitions = @(
                    Get-Partition -DiskNumber $diskNumber -ErrorAction Stop |
                    Where-Object {
                        $_.Type -ne "Reserved" -and
                        $_.Size -gt 1GB
                    } |
                    Sort-Object Size -Descending
                )

                if (-not $partitions -or $partitions.Count -eq 0) {
                    throw "No suitable partitions found on mounted VHDX disk number $diskNumber."
                }

                $windowsDrive = $null

                foreach ($partition in $partitions) {
                    Write-Output "Checking partition $($partition.PartitionNumber), size $([math]::Round($partition.Size / 1GB, 2)) GiB..."

                    $volumes = @()

                    try {
                        $volumes = @($partition | Get-Volume -ErrorAction SilentlyContinue)
                    }
                    catch {
                        $volumes = @()
                    }

                    if (-not $volumes -or $volumes.Count -eq 0) {
                        Write-Output "No volume found for partition $($partition.PartitionNumber)."
                        continue
                    }

                    foreach ($volume in $volumes) {
                        $drive = $null

                        if ($volume.DriveLetter) {
                            $drive = [string]$volume.DriveLetter
                        }
                        else {
                            $assignedDriveLetter = Get-FreeDriveLetterLocal
                            $accessPath = "$assignedDriveLetter`:\"

                            Write-Output "Assigning temporary drive letter $assignedDriveLetter to partition $($partition.PartitionNumber)..."

                            Add-PartitionAccessPath `
                                -DiskNumber $diskNumber `
                                -PartitionNumber $partition.PartitionNumber `
                                -AccessPath $accessPath `
                                -ErrorAction Stop | Out-Null

                            $temporaryAccessPaths += [PSCustomObject]@{
                                DiskNumber      = $diskNumber
                                PartitionNumber = $partition.PartitionNumber
                                AccessPath      = $accessPath
                            }

                            Start-Sleep -Seconds 2
                            $drive = $assignedDriveLetter
                        }

                        if ($drive -and (Test-Path "$drive`:\Windows")) {
                            $windowsDrive = $drive
                            Write-Output "Windows volume found on drive $windowsDrive`:"
                            break
                        }
                    }

                    if ($windowsDrive) {
                        break
                    }
                }

                if (-not $windowsDrive) {
                    throw "Unable to find Windows volume inside mounted VHDX."
                }

                $pantherPath = "$windowsDrive`:\Windows\Panther"

                if (-not (Test-Path $pantherPath)) {
                    New-Item -Path $pantherPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }

                $computerNameXml = ConvertTo-XmlEscapedTextLocal -Value $VmName
                $localUserXml = ConvertTo-XmlEscapedTextLocal -Value $LocalAdminUsername
                $localPassXml = ConvertTo-XmlEscapedTextLocal -Value $LocalAdminPlainPassword
                $timeZoneXml = ConvertTo-XmlEscapedTextLocal -Value $TimeZone

                $unattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$computerNameXml</ComputerName>
      <TimeZone>$timeZoneXml</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-GB</InputLocale>
      <SystemLocale>en-GB</SystemLocale>
      <UILanguage>en-GB</UILanguage>
      <UserLocale>en-GB</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount>
            <Password>
              <Value>$localPassXml</Value>
              <PlainText>true</PlainText>
            </Password>
            <Description>Local administrator</Description>
            <DisplayName>$localUserXml</DisplayName>
            <Group>Administrators</Group>
            <Name>$localUserXml</Name>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@

                $unattendPath = Join-Path $pantherPath "Unattend.xml"
                Set-Content -Path $unattendPath -Value $unattendXml -Encoding UTF8 -Force -ErrorAction Stop

                Write-Output "Injected unattend.xml to '$unattendPath'."

                # Fallback account creation:
                # Use a very small SetupComplete.cmd implementation using net.exe rather than
                # Get-LocalUser/New-LocalUser. This avoids LocalAccounts module hangs during Windows setup.
                $setupScriptsPath = "$windowsDrive`:\Windows\Setup\Scripts"

                if (-not (Test-Path $setupScriptsPath)) {
                    New-Item -Path $setupScriptsPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }

                $setupCompleteCmdPath = Join-Path $setupScriptsPath "SetupComplete.cmd"

                $setupLogPathInGuest = "C:\Windows\Temp\AVDHybrid-SetupComplete.log"

                # Escape for CMD. Percent signs must be doubled in batch files.
                $cmdSafeUsername = $LocalAdminUsername.Replace('"', '')
                $cmdSafePassword = $LocalAdminPlainPassword.Replace('"', '').Replace('%', '%%')

                $setupCompleteCmd = @"
@echo off
setlocal EnableExtensions DisableDelayedExpansion

echo ================================================== >> "$setupLogPathInGuest"
echo AVD Hybrid SetupComplete starting %DATE% %TIME% >> "$setupLogPathInGuest"
echo Running as: >> "$setupLogPathInGuest"
whoami >> "$setupLogPathInGuest" 2>>&1

set "AVDUSER=$cmdSafeUsername"
set "AVDPASS=$cmdSafePassword"

echo Creating or resetting local admin account [%AVDUSER%]... >> "$setupLogPathInGuest"

net user "%AVDUSER%" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo User exists. Resetting password and enabling account. >> "$setupLogPathInGuest"
    net user "%AVDUSER%" "%AVDPASS%" /active:yes >> "$setupLogPathInGuest" 2>>&1
) else (
    echo User does not exist. Creating account. >> "$setupLogPathInGuest"
    net user "%AVDUSER%" "%AVDPASS%" /add /active:yes >> "$setupLogPathInGuest" 2>>&1
)

echo Adding account to local Administrators group... >> "$setupLogPathInGuest"
net localgroup Administrators "%AVDUSER%" /add >> "$setupLogPathInGuest" 2>>&1

echo Setting password never expires where supported... >> "$setupLogPathInGuest"
wmic UserAccount where "Name='%AVDUSER%'" set PasswordExpires=False >> "$setupLogPathInGuest" 2>>&1

echo Enabling PowerShell remoting best effort... >> "$setupLogPathInGuest"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Enable-PSRemoting -Force -SkipNetworkProfileCheck } catch { Write-Output `$_.Exception.Message }" >> "$setupLogPathInGuest" 2>>&1

echo Verifying local user... >> "$setupLogPathInGuest"
net user "%AVDUSER%" >> "$setupLogPathInGuest" 2>>&1

echo AVD Hybrid SetupComplete finished %DATE% %TIME% >> "$setupLogPathInGuest"

del /f /q "%WINDIR%\Setup\Scripts\SetupComplete.cmd" >> "$setupLogPathInGuest" 2>>&1

exit /b 0
"@

                Set-Content -Path $setupCompleteCmdPath -Value $setupCompleteCmd -Encoding ASCII -Force -ErrorAction Stop

                Write-Output "Injected simplified SetupComplete local admin script to '$setupCompleteCmdPath'."

            }
            finally {
                foreach ($item in $temporaryAccessPaths) {
                    try {
                        Remove-PartitionAccessPath `
                            -DiskNumber $item.DiskNumber `
                            -PartitionNumber $item.PartitionNumber `
                            -AccessPath $item.AccessPath `
                            -ErrorAction SilentlyContinue | Out-Null
                    }
                    catch {
                        Write-Output "Could not remove temporary access path $($item.AccessPath): $($_.Exception.Message)"
                    }
                }

                if ($mounted) {
                    Dismount-VHD -Path $destVhdPath -ErrorAction SilentlyContinue
                }
            }
        }

        Write-Output "Creating Hyper-V VM '$VmName'..."

        try {
            Write-Output "STEP [NEW_VM_NO_VHD] starting..."
            $vm = New-VM `
                -Name $VmName `
                -Generation $Generation `
                -MemoryStartupBytes $MemoryStartupBytes `
                -Path $vmFolder `
                -NoVHD `
                -ErrorAction Stop

            if (-not $vm) {
                $vm = Get-VM -Name $VmName -ErrorAction Stop | Select-Object -First 1
            }

            Write-Output "STEP [NEW_VM_NO_VHD] completed. VMId: $($vm.Id)"
        }
        catch {
            throw "Hyper-V VM creation failed at step [NEW_VM_NO_VHD]. $($_.Exception.Message)"
        }

        try {
            Write-Output "STEP [REMOVE_DEFAULT_NICS] starting..."
            $existingAdapters = @(Get-VMNetworkAdapter -VM $vm -ErrorAction SilentlyContinue)

            foreach ($adapter in $existingAdapters) {
                Write-Output "Removing existing VM network adapter '$($adapter.Name)' from '$VmName'..."
                Remove-VMNetworkAdapter `
                    -VMNetworkAdapter $adapter `
                    -ErrorAction SilentlyContinue
            }

            Write-Output "STEP [REMOVE_DEFAULT_NICS] completed."
        }
        catch {
            throw "Hyper-V VM creation failed at step [REMOVE_DEFAULT_NICS]. $($_.Exception.Message)"
        }

        try {
            Write-Output "STEP [ADD_BOOT_DISK] starting..."
            Add-VMHardDiskDrive `
                -VM $vm `
                -ControllerType SCSI `
                -ControllerNumber 0 `
                -ControllerLocation 0 `
                -Path $destVhdPath `
                -ErrorAction Stop

            Write-Output "STEP [ADD_BOOT_DISK] completed."
        }
        catch {
            throw "Hyper-V VM creation failed at step [ADD_BOOT_DISK]. $($_.Exception.Message)"
        }

        try {
            Write-Output "STEP [GET_BOOT_DISK] starting..."
            $bootDisk = Get-VMHardDiskDrive -VM $vm -ErrorAction Stop |
                Where-Object { $_.Path -ieq $destVhdPath } |
                Select-Object -First 1

            if (-not $bootDisk) {
                throw "Unable to find attached boot disk '$destVhdPath' on VM '$VmName'."
            }

            Write-Output "STEP [GET_BOOT_DISK] completed."
        }
        catch {
            throw "Hyper-V VM creation failed at step [GET_BOOT_DISK]. $($_.Exception.Message)"
        }

        try {
            Write-Output "STEP [SET_FIRMWARE] starting..."
            Set-VMFirmware `
                -VM $vm `
                -FirstBootDevice $bootDisk `
                -ErrorAction Stop

            Write-Output "STEP [SET_FIRMWARE] completed."
        }
        catch {
            throw "Hyper-V VM creation failed at step [SET_FIRMWARE]. $($_.Exception.Message)"
        }

        try {
            Write-Output "STEP [SET_PROCESSOR] starting..."
            Set-VMProcessor -VM $vm -Count $ProcessorCount -ErrorAction Stop
            Write-Output "STEP [SET_PROCESSOR] completed."
        }
        catch {
            throw "Hyper-V VM creation failed at step [SET_PROCESSOR]. $($_.Exception.Message)"
        }

        if ($UseDynamicMemory) {
            try {
                Write-Output "STEP [SET_DYNAMIC_MEMORY] starting..."
                Set-VMMemory `
                    -VM $vm `
                    -DynamicMemoryEnabled $true `
                    -MinimumBytes $MemoryMinimumBytes `
                    -StartupBytes $MemoryStartupBytes `
                    -MaximumBytes $MemoryMaximumBytes `
                    -ErrorAction Stop

                Write-Output "STEP [SET_DYNAMIC_MEMORY] completed."
            }
            catch {
                throw "Hyper-V VM creation failed at step [SET_DYNAMIC_MEMORY]. $($_.Exception.Message)"
            }
        }

        try {
            Write-Output "STEP [ADD_NIC_DISCONNECTED] starting..."
            Add-VMNetworkAdapter `
                -VM $vm `
                -Name "AVD-NIC" `
                -ErrorAction Stop

            Write-Output "STEP [ADD_NIC_DISCONNECTED] completed."
        }
        catch {
            throw "Hyper-V VM creation failed at step [ADD_NIC_DISCONNECTED]. $($_.Exception.Message)"
        }

        try {
            Write-Output "STEP [CONNECT_NIC_TO_SWITCH] starting..."

            $switchMatches = @(Get-VMSwitch | Where-Object { $_.Name -eq $SwitchName })

            if ($switchMatches.Count -ne 1) {
                $switchSummary = @(Get-VMSwitch | Select-Object Name, Id, SwitchType | ForEach-Object {
                    "Name=$($_.Name); Id=$($_.Id); Type=$($_.SwitchType)"
                }) -join " | "

                throw "Expected exactly one Hyper-V switch named '$SwitchName' but found $($switchMatches.Count). Switches on host: $switchSummary"
            }

            $adapterMatches = @(Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop | Where-Object { $_.Name -eq "AVD-NIC" })

            if ($adapterMatches.Count -ne 1) {
                $adapterSummary = @(Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue | Select-Object Name, SwitchName, MacAddress | ForEach-Object {
                    "Name=$($_.Name); Switch=$($_.SwitchName); Mac=$($_.MacAddress)"
                }) -join " | "

                throw "Expected exactly one network adapter named 'AVD-NIC' on VM '$VmName' but found $($adapterMatches.Count). Adapters: $adapterSummary"
            }

            Write-Output "Connecting adapter 'AVD-NIC' on VM '$VmName' to switch '$($switchMatches[0].Name)'..."

            # Use VMName + adapter Name rather than passing the adapter object. This avoids object-binding issues seen through remoting.
            Connect-VMNetworkAdapter `
                -VMName $VmName `
                -Name "AVD-NIC" `
                -SwitchName ([string]$switchMatches[0].Name) `
                -ErrorAction Stop

            $connectedNic = Get-VMNetworkAdapter -VMName $VmName -Name "AVD-NIC" -ErrorAction Stop

            Write-Output "NIC connected. Adapter='$($connectedNic.Name)', Switch='$($connectedNic.SwitchName)', Mac='$($connectedNic.MacAddress)'."
            Write-Output "STEP [CONNECT_NIC_TO_SWITCH] completed."
        }
        catch {
            throw "Hyper-V VM creation failed at step [CONNECT_NIC_TO_SWITCH]. $($_.Exception.Message)"
        }

        try {
            Write-Output "STEP [ENABLE_GUEST_SERVICE_INTERFACE] starting..."
            Enable-VMIntegrationService -VMName $VmName -Name "Guest Service Interface" -ErrorAction SilentlyContinue
            Write-Output "STEP [ENABLE_GUEST_SERVICE_INTERFACE] completed."
        }
        catch {
            Write-Output "STEP [ENABLE_GUEST_SERVICE_INTERFACE] warning: $($_.Exception.Message)"
        }

        try {
            Write-Output "STEP [START_VM] starting..."
            Start-VM -VM $vm -ErrorAction Stop
            Write-Output "STEP [START_VM] completed."
        }
        catch {
            throw "Hyper-V VM creation failed at step [START_VM]. $($_.Exception.Message)"
        }

        Write-Output "Hyper-V VM '$VmName' created and started."
    }

    $output = Invoke-HyperVHostCommand `
        -ScriptBlock $scriptBlock `
        -ArgumentList @(
            $VmName,
            $TemplatePath,
            $HyperVVmRootPath,
            $HyperVSwitchName,
            $VmGeneration,
            $MemoryStartupBytes,
            $UseDynamicMemory,
            $MemoryMinimumBytes,
            $MemoryMaximumBytes,
            $ProcessorCount,
            $InjectUnattendXml,
            $GuestLocalAdminCredential.UserName,
            $localAdminPlainPassword,
            $TimeZone
        )

    $output | ForEach-Object { Write-Log -Level "INFO" -Component "HYPERV" -Message $_ }
}

function Wait-ForPowerShellDirect {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [pscredential]$GuestLocalAdminCredential,

        [int]$TimeoutMinutes = 30,

        [int]$PollSeconds = 20,

        [Parameter(Mandatory = $true)]
        [ref]$Ready
    )

    $Ready.Value = $false

    Write-Log -Level "INFO" -Component "GUEST" -Message "Waiting for PowerShell Direct to become available on '$VmName'..."

    $scriptBlock = {
        param(
            [string]$VmName,
            [pscredential]$GuestCredential,
            [int]$TimeoutMinutes,
            [int]$PollSeconds
        )

        Import-Module Hyper-V -ErrorAction Stop

        $maxChecks = [math]::Ceiling(($TimeoutMinutes * 60) / $PollSeconds)

        for ($i = 1; $i -le $maxChecks; $i++) {
            try {
                $result = Invoke-Command `
                    -VMName $VmName `
                    -Credential $GuestCredential `
                    -ScriptBlock { $env:COMPUTERNAME } `
                    -ErrorAction Stop

                if ($result) {
                    Write-Output "READY"
                    return
                }
            }
            catch {
                Write-Output ("WAIT {0}/{1}: {2}" -f $i, $maxChecks, $_.Exception.Message)
            }

            Start-Sleep -Seconds $PollSeconds
        }

        Write-Output "NOT_READY"
    }

    $output = Invoke-HyperVHostCommand `
        -ScriptBlock $scriptBlock `
        -ArgumentList @($VmName, $GuestLocalAdminCredential, $TimeoutMinutes, $PollSeconds)

    foreach ($line in $output) {
        if ($line -eq "READY") {
            Write-Log -Level "SUCCESS" -Component "GUEST" -Message "PowerShell Direct is ready on '$VmName'."
            $Ready.Value = $true
            return
        }

        Write-Log -Level "INFO" -Component "GUEST" -Message $line
    }
}

function Invoke-GuestDomainJoin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [pscredential]$GuestLocalAdminCredential,

        [Parameter(Mandatory = $true)]
        [pscredential]$DomainJoinCredential
    )

    Write-Log -Level "INFO" -Component "ADDS" -Message "Joining '$VmName' to domain '$DomainFqdn'..."

    $scriptBlock = {
        param(
            [string]$VmName,
            [pscredential]$GuestCredential,
            [pscredential]$DomainJoinCredential,
            [string]$DomainFqdn,
            [string]$DomainOuPath
        )

        Import-Module Hyper-V -ErrorAction Stop

        try {
            Invoke-Command `
                -VMName $VmName `
                -Credential $GuestCredential `
                -ScriptBlock {
                    param(
                        [pscredential]$DomainJoinCredential,
                        [string]$DomainFqdn,
                        [string]$DomainOuPath,
                        [string]$ExpectedComputerName
                    )

                    $ErrorActionPreference = "Stop"

                    $computerSystem = Get-CimInstance Win32_ComputerSystem

                    if ($computerSystem.PartOfDomain -and $computerSystem.Domain -ieq $DomainFqdn) {
                        Write-Output "ALREADY_DOMAIN_JOINED"
                        return
                    }

                    if ($env:COMPUTERNAME -ine $ExpectedComputerName) {
                        throw "Guest computer name '$env:COMPUTERNAME' does not match expected name '$ExpectedComputerName'."
                    }

                    $joinParameters = @{
                        DomainName = $DomainFqdn
                        Credential = $DomainJoinCredential
                        Force      = $true
                        Restart    = $true
                        PassThru   = $true
                        Verbose    = $true
                    }

                    if (-not [string]::IsNullOrWhiteSpace($DomainOuPath)) {
                        $joinParameters.OUPath = $DomainOuPath
                    }

                    Add-Computer @joinParameters
                } `
                -ArgumentList @($DomainJoinCredential, $DomainFqdn, $DomainOuPath, $VmName) `
                -ErrorAction Stop
        }
        catch {
            # A PowerShell Direct session commonly ends while Add-Computer -Restart reboots the guest.
            # Treat the known session-ended condition as expected; all other errors are rethrown.
            $message = $_.Exception.Message

            if (
                $message -match "remote session might have ended" -or
                $message -match "The I/O operation has been aborted" -or
                $message -match "pipeline has been stopped" -or
                $message -match "virtual machine.*restarted"
            ) {
                Write-Output "DOMAIN_JOIN_REBOOT_SESSION_ENDED"
                return
            }

            throw
        }
    }

    $output = Invoke-HyperVHostCommand `
        -ScriptBlock $scriptBlock `
        -ArgumentList @($VmName, $GuestLocalAdminCredential, $DomainJoinCredential, $DomainFqdn, $DomainOuPath)

    $output | ForEach-Object { Write-Log -Level "INFO" -Component "ADDS" -Message $_ }
}

function Wait-ForDomainJoinRestartAndStability {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [pscredential]$GuestLocalAdminCredential,

        [int]$TimeoutMinutes = 30,

        [int]$PollSeconds = 20,

        [int]$RequiredStableChecks = 3,

        [int]$SettleSeconds = 90,

        [Parameter(Mandatory = $true)]
        [ref]$Ready
    )

    $Ready.Value = $false

    Write-Log -Level "INFO" -Component "GUEST" -Message "Waiting for domain-join restart and stable guest state on '$VmName'..."

    $scriptBlock = {
        param(
            [string]$VmName,
            [pscredential]$GuestCredential,
            [string]$DomainFqdn,
            [int]$TimeoutMinutes,
            [int]$PollSeconds,
            [int]$RequiredStableChecks,
            [int]$SettleSeconds
        )

        Import-Module Hyper-V -ErrorAction Stop

        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $sawUnavailable = $false
        $stableChecks = 0
        $attempt = 0

        while ((Get-Date) -lt $deadline) {
            $attempt++

            $vm = Get-VM -Name $VmName -ErrorAction Stop

            if ($vm.State -ne "Running") {
                $sawUnavailable = $true
                $stableChecks = 0
                Write-Output ("WAIT_REBOOT {0}: VM state is {1}." -f $attempt, $vm.State)
                Start-Sleep -Seconds $PollSeconds
                continue
            }

            try {
                $status = Invoke-Command `
                    -VMName $VmName `
                    -Credential $GuestCredential `
                    -ScriptBlock {
                        param([string]$DomainFqdn)

                        $ErrorActionPreference = "Stop"

                        $computerSystem = Get-CimInstance Win32_ComputerSystem
                        $network = Get-NetIPConfiguration | Where-Object {
                            $_.IPv4Address -and $_.IPv4DefaultGateway
                        } | Select-Object -First 1

                        $dnsReady = $false
                        try {
                            Resolve-DnsName `
                                -Name ("_ldap._tcp.dc._msdcs.{0}" -f $DomainFqdn) `
                                -Type SRV `
                                -ErrorAction Stop | Out-Null
                            $dnsReady = $true
                        }
                        catch {
                            $dnsReady = $false
                        }

                        [pscustomobject]@{
                            ComputerName = $env:COMPUTERNAME
                            PartOfDomain = [bool]$computerSystem.PartOfDomain
                            Domain       = [string]$computerSystem.Domain
                            HasIPv4      = [bool]($null -ne $network)
                            DnsReady     = [bool]$dnsReady
                            Workstation  = [string](Get-Service LanmanWorkstation -ErrorAction Stop).Status
                            Netlogon     = [string](Get-Service Netlogon -ErrorAction SilentlyContinue).Status
                        }
                    } `
                    -ArgumentList $DomainFqdn `
                    -ErrorAction Stop

                $healthy = (
                    $status.PartOfDomain -and
                    $status.Domain -ieq $DomainFqdn -and
                    $status.HasIPv4 -and
                    $status.DnsReady -and
                    $status.Workstation -eq "Running"
                )

                if ($healthy) {
                    $stableChecks++
                    Write-Output ("STABLE_CHECK {0}/{1}: Domain={2}; IPv4={3}; DNS={4}; Workstation={5}; Netlogon={6}" -f `
                        $stableChecks,
                        $RequiredStableChecks,
                        $status.Domain,
                        $status.HasIPv4,
                        $status.DnsReady,
                        $status.Workstation,
                        $status.Netlogon)
                }
                else {
                    $stableChecks = 0
                    Write-Output ("WAIT_HEALTH {0}: PartOfDomain={1}; Domain={2}; IPv4={3}; DNS={4}; Workstation={5}; Netlogon={6}" -f `
                        $attempt,
                        $status.PartOfDomain,
                        $status.Domain,
                        $status.HasIPv4,
                        $status.DnsReady,
                        $status.Workstation,
                        $status.Netlogon)
                }

                if ($stableChecks -ge $RequiredStableChecks) {
                    if (-not $sawUnavailable) {
                        Write-Output "REBOOT_OUTAGE_NOT_OBSERVED: The guest may have restarted before monitoring began. Domain membership is confirmed."
                    }

                    if ($SettleSeconds -gt 0) {
                        Write-Output ("SETTLING: Waiting an additional {0} second(s) for startup processing and Group Policy." -f $SettleSeconds)
                        Start-Sleep -Seconds $SettleSeconds
                    }

                    Write-Output "DOMAIN_READY"
                    return
                }
            }
            catch {
                $sawUnavailable = $true
                $stableChecks = 0
                Write-Output ("WAIT_PSDIRECT {0}: {1}" -f $attempt, $_.Exception.Message)
            }

            Start-Sleep -Seconds $PollSeconds
        }

        Write-Output "DOMAIN_NOT_READY"
    }

    $output = Invoke-HyperVHostCommand `
        -ScriptBlock $scriptBlock `
        -ArgumentList @(
            $VmName,
            $GuestLocalAdminCredential,
            $DomainFqdn,
            $TimeoutMinutes,
            $PollSeconds,
            $RequiredStableChecks,
            $SettleSeconds
        )

    foreach ($line in $output) {
        if ($line -eq "DOMAIN_READY") {
            Write-Log -Level "SUCCESS" -Component "GUEST" -Message "'$VmName' is domain joined, network ready and stable after restart."
            $Ready.Value = $true
            return
        }

        if ($line -eq "DOMAIN_NOT_READY") {
            Write-Log -Level "ERROR" -Component "GUEST" -Message "'$VmName' did not become stable after the domain join within $TimeoutMinutes minute(s)."
            continue
        }

        Write-Log -Level "INFO" -Component "GUEST" -Message $line
    }
}

function Install-ArcAgentInGuest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [pscredential]$GuestLocalAdminCredential,

        [Parameter(Mandatory = $true)]
        [string]$ServicePrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$ServicePrincipalSecret
    )

    Write-Log -Level "INFO" -Component "ARC" -Message "Installing and connecting Azure Arc agent inside '$VmName'..."

    $tagPairs = @()

    foreach ($key in $ArcTags.Keys) {
        $tagPairs += ("{0}={1}" -f $key, $ArcTags[$key])
    }

    $tagString = $tagPairs -join ","
    $lastError = $null

    for ($attempt = 1; $attempt -le $ArcInstallRetryCount; $attempt++) {
        Write-Log -Level "INFO" -Component "ARC" -Message "Azure Arc guest operation attempt $attempt of $ArcInstallRetryCount for '$VmName'."

        try {
            $scriptBlock = {
                param(
                    [string]$VmName,
                    [pscredential]$GuestCredential,
                    [string]$ArcAgentDownloadUrl,
                    [string]$ArcInstallFolder,
                    [string]$TenantId,
                    [string]$ArcSubscriptionId,
                    [string]$ArcResourceGroupName,
                    [string]$ArcLocation,
                    [string]$ArcCloud,
                    [string]$ServicePrincipalId,
                    [string]$ServicePrincipalSecret,
                    [string]$TagString
                )

                Import-Module Hyper-V -ErrorAction Stop

                Invoke-Command `
                    -VMName $VmName `
                    -Credential $GuestCredential `
                    -ScriptBlock {
                        param(
                            [string]$ArcAgentDownloadUrl,
                            [string]$ArcInstallFolder,
                            [string]$TenantId,
                            [string]$ArcSubscriptionId,
                            [string]$ArcResourceGroupName,
                            [string]$ArcLocation,
                            [string]$ArcCloud,
                            [string]$ServicePrincipalId,
                            [string]$ServicePrincipalSecret,
                            [string]$TagString,
                            [string]$ResourceName
                        )

                        $ErrorActionPreference = "Stop"
                        $ConfirmPreference = "None"
                        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

                        if (-not (Test-Path $ArcInstallFolder)) {
                            New-Item -Path $ArcInstallFolder -ItemType Directory -Force | Out-Null
                        }

                        $msiPath = Join-Path $ArcInstallFolder "AzureConnectedMachineAgent.msi"
                        $installLog = Join-Path $ArcInstallFolder "AzureConnectedMachineAgent-install.log"
                        $connectLog = Join-Path $ArcInstallFolder "AzureConnectedMachineAgent-connect.log"
                        $azcmagent = "C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe"

                        if (-not (Test-Path $azcmagent)) {
                            if (-not (Test-Path $msiPath)) {
                                Write-Output "Downloading Azure Connected Machine Agent..."
                                Invoke-WebRequest `
                                    -Uri $ArcAgentDownloadUrl `
                                    -OutFile $msiPath `
                                    -UseBasicParsing `
                                    -ErrorAction Stop
                            }
                            else {
                                Write-Output "Using previously downloaded Arc agent MSI '$msiPath'."
                            }

                            Write-Output "Installing Azure Connected Machine Agent..."
                            $installArgs = "/i `"$msiPath`" /qn /norestart /l*v `"$installLog`""
                            $install = Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgs -Wait -PassThru

                            if ($install.ExitCode -notin @(0, 3010, 1641)) {
                                throw "Azure Connected Machine Agent MSI install failed with exit code $($install.ExitCode). Log: $installLog"
                            }

                            if ($install.ExitCode -in @(3010, 1641)) {
                                Write-Output "Arc agent installer returned reboot-required exit code $($install.ExitCode). Continuing and validating installation."
                            }

                            $agentDeadline = (Get-Date).AddMinutes(5)
                            while (-not (Test-Path $azcmagent) -and (Get-Date) -lt $agentDeadline) {
                                Start-Sleep -Seconds 5
                            }
                        }
                        else {
                            Write-Output "Azure Connected Machine Agent is already installed."
                        }

                        if (-not (Test-Path $azcmagent)) {
                            throw "azcmagent.exe was not found at '$azcmagent' after installation."
                        }

                        $himds = Get-Service -Name himds -ErrorAction SilentlyContinue
                        if ($himds -and $himds.Status -ne "Running") {
                            Write-Output "Starting Azure Connected Machine Agent service..."
                            Start-Service -Name himds -ErrorAction Stop
                        }

                        function Get-ArcAgentConnectionStateLocal {
                            param(
                                [Parameter(Mandatory = $true)]
                                [string]$AzcmAgentPath
                            )

                            # Prefer structured JSON output. Agent releases have used slightly different
                            # property names, so inspect the common variants and then fall back to text.
                            $jsonOutput = @(& $AzcmAgentPath show --json 2>&1)
                            $jsonExitCode = $LASTEXITCODE
                            $jsonText = $jsonOutput -join [Environment]::NewLine

                            if ($jsonExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($jsonText)) {
                                try {
                                    $json = $jsonText | ConvertFrom-Json -ErrorAction Stop
                                    $statusCandidates = @(
                                        $json.status,
                                        $json.agentStatus,
                                        $json.agent_status,
                                        $json.agent.status,
                                        $json.connectionStatus,
                                        $json.connection_status
                                    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

                                    foreach ($candidate in $statusCandidates) {
                                        if ([string]$candidate -ieq "Connected") {
                                            return [pscustomobject]@{
                                                Connected = $true
                                                Status    = [string]$candidate
                                                Output    = $jsonText
                                            }
                                        }
                                    }
                                }
                                catch {
                                    # Fall through to the human-readable output parser.
                                }
                            }

                            $showOutput = @(& $AzcmAgentPath show 2>&1)
                            $showExitCode = $LASTEXITCODE
                            $showText = $showOutput -join [Environment]::NewLine

                            # Current output uses "Agent Status : Connected". Keep the looser
                            # "Status : Connected" fallback for compatibility with older agents.
                            $isConnected = $showExitCode -eq 0 -and (
                                $showText -match "(?im)^\s*Agent\s+Status\s*:\s*Connected\s*$" -or
                                $showText -match "(?im)^\s*Status\s*:\s*Connected\s*$"
                            )

                            return [pscustomobject]@{
                                Connected = [bool]$isConnected
                                Status    = $(if ($isConnected) { "Connected" } else { "NotConnected" })
                                Output    = $showText
                            }
                        }

                        $initialArcState = Get-ArcAgentConnectionStateLocal -AzcmAgentPath $azcmagent

                        if ($initialArcState.Connected) {
                            Write-Output "Azure Connected Machine Agent is already connected."
                            Write-Output $initialArcState.Output
                            return
                        }

                        Write-Output "Connecting machine to Azure Arc subscription '$ArcSubscriptionId'..."

                        $connectArgs = @(
                            "connect",
                            "--service-principal-id", $ServicePrincipalId,
                            "--service-principal-secret", $ServicePrincipalSecret,
                            "--tenant-id", $TenantId,
                            "--subscription-id", $ArcSubscriptionId,
                            "--resource-group", $ArcResourceGroupName,
                            "--location", $ArcLocation,
                            "--resource-name", $ResourceName,
                            "--cloud", $ArcCloud
                        )

                        if (-not [string]::IsNullOrWhiteSpace($TagString)) {
                            $connectArgs += @("--tags", $TagString)
                        }

                        $connectOutput = @(& $azcmagent @connectArgs 2>&1)
                        $connectExitCode = $LASTEXITCODE
                        $connectOutput | Set-Content -Path $connectLog -Encoding UTF8 -Force
                        $connectOutput | ForEach-Object { Write-Output $_ }

                        if ($connectExitCode -ne 0) {
                            throw "azcmagent connect failed with exit code $connectExitCode. Log: $connectLog"
                        }

                        $verifyDeadline = (Get-Date).AddMinutes(5)
                        $connected = $false

                        $statusCheck = 0
                        while ((Get-Date) -lt $verifyDeadline) {
                            $statusCheck++
                            $arcState = Get-ArcAgentConnectionStateLocal -AzcmAgentPath $azcmagent
                            Write-Output "Arc connection status check ${statusCheck}: $($arcState.Status)"

                            if ($arcState.Connected) {
                                Write-Output $arcState.Output
                                $connected = $true
                                break
                            }

                            Start-Sleep -Seconds 10
                        }

                        if (-not $connected) {
                            throw "Azure Connected Machine Agent did not report Connected status after azcmagent connect."
                        }

                        Write-Output "Azure Arc connection completed and verified."
                    } `
                    -ArgumentList @(
                        $ArcAgentDownloadUrl,
                        $ArcInstallFolder,
                        $TenantId,
                        $ArcSubscriptionId,
                        $ArcResourceGroupName,
                        $ArcLocation,
                        $ArcCloud,
                        $ServicePrincipalId,
                        $ServicePrincipalSecret,
                        $TagString,
                        $VmName
                    ) `
                    -ErrorAction Stop
            }

            $output = Invoke-HyperVHostCommand `
                -ScriptBlock $scriptBlock `
                -ArgumentList @(
                    $VmName,
                    $GuestLocalAdminCredential,
                    $ArcAgentDownloadUrl,
                    $ArcInstallFolder,
                    $TenantId,
                    $ArcSubscriptionId,
                    $ArcResourceGroupName,
                    $ArcLocation,
                    $ArcCloud,
                    $ServicePrincipalId,
                    $ServicePrincipalSecret,
                    $tagString
                )

            $output | ForEach-Object { Write-Log -Level "INFO" -Component "ARC" -Message $_ }
            Write-Log -Level "SUCCESS" -Component "ARC" -Message "Azure Arc agent installation and connection succeeded for '$VmName'."
            return
        }
        catch {
            $lastError = $_
            Write-Log -Level "WARN" -Component "ARC" -Message "Azure Arc attempt $attempt failed for '$VmName': $($_.Exception.Message)"

            if ($attempt -lt $ArcInstallRetryCount) {
                Write-Log -Level "INFO" -Component "ARC" -Message "Waiting for PowerShell Direct to become available before retrying Arc operation..."

                $psDirectReady = $false
                Wait-ForPowerShellDirect `
                    -VmName $VmName `
                    -GuestLocalAdminCredential $GuestLocalAdminCredential `
                    -TimeoutMinutes 10 `
                    -PollSeconds 20 `
                    -Ready ([ref]$psDirectReady)

                if (-not $psDirectReady) {
                    Write-Log -Level "WARN" -Component "ARC" -Message "PowerShell Direct was not ready before Arc retry $($attempt + 1). The retry will still be attempted."
                }

                Start-Sleep -Seconds $ArcInstallRetryDelaySeconds
            }
        }
    }

    if ($lastError) {
        throw "Azure Arc installation/connection failed after $ArcInstallRetryCount attempts. Last error: $($lastError.Exception.Message)"
    }

    throw "Azure Arc installation/connection failed after $ArcInstallRetryCount attempts."
}


################################################################################################################
# MAIN
################################################################################################################

try {
    Write-StepBanner -Message "START"
    Write-Log -Level "INFO" -Component "RUNBOOK" -Message "Stage 2 AVD Hybrid deployment starting."
    Write-Log -Level "INFO" -Component "RUNBOOK" -Message "VmNamePrefix: $VmNamePrefix"
    Write-Log -Level "INFO" -Component "RUNBOOK" -Message "SessionHostCount: $SessionHostCount"
    Write-Log -Level "INFO" -Component "RUNBOOK" -Message "OverwriteExisting: $OverwriteExisting"

    if ($SessionHostCount -lt 1) {
        throw "SessionHostCount must be at least 1."
    }

    if ([string]::IsNullOrWhiteSpace($TenantId) -or $TenantId -eq "00000000-0000-0000-0000-000000000000") {
        throw "TenantId has not been configured."
    }

    if ([string]::IsNullOrWhiteSpace($KeyVaultName)) {
        throw "KeyVaultName has not been configured."
    }

    Connect-RunbookAz

    Write-StepBanner -Message "CONFIGURATION"

    $templatePath = Get-TemplatePathFromAutomationVariable
    $currentGalleryVersion = Get-CurrentGalleryVersionFromAutomationVariable

    Write-Log -Level "INFO" -Component "CONFIG" -Message "AVD subscription: $AvdSubscriptionId"
    Write-Log -Level "INFO" -Component "CONFIG" -Message "Arc subscription: $ArcSubscriptionId"
    Write-Log -Level "INFO" -Component "CONFIG" -Message "Key Vault subscription: $KeyVaultSubscriptionId"
    Write-Log -Level "INFO" -Component "CONFIG" -Message "Template path: $templatePath"
    Write-Log -Level "INFO" -Component "CONFIG" -Message "Current gallery version: $currentGalleryVersion"
    Write-Log -Level "INFO" -Component "CONFIG" -Message "Hyper-V host: $HyperVHostName"
    Write-Log -Level "INFO" -Component "CONFIG" -Message "Hyper-V VM root path: $HyperVVmRootPath"
    Write-Log -Level "INFO" -Component "CONFIG" -Message "Hyper-V switch: $HyperVSwitchName"
    Write-Log -Level "INFO" -Component "CONFIG" -Message "Arc resource group: $ArcResourceGroupName"
    Write-Log -Level "INFO" -Component "CONFIG" -Message "Host pool: $HostPoolName"

    Write-StepBanner -Message "KEY VAULT"

    $guestLocalAdminCredential = Get-PSCredentialFromKeyVault `
        -VaultName $KeyVaultName `
        -UsernameSecretName $LocalAdminUsernameSecretName `
        -PasswordSecretName $LocalAdminPasswordSecretName

    $domainJoinCredential = Get-PSCredentialFromKeyVault `
        -VaultName $KeyVaultName `
        -UsernameSecretName $DomainJoinUsernameSecretName `
        -PasswordSecretName $DomainJoinPasswordSecretName

    $arcSpId = Get-PlainSecretOrThrow `
        -VaultName $KeyVaultName `
        -SecretName $ArcServicePrincipalIdSecretName

    $arcSpSecret = Get-PlainSecretOrThrow `
        -VaultName $KeyVaultName `
        -SecretName $ArcServicePrincipalSecretSecretName

    Write-Log -Level "SUCCESS" -Component "KEYVAULT" -Message "Required secrets retrieved."

    Write-StepBanner -Message "VM NAME PLAN"

    $existingHostNames = @(Get-ExistingSessionHostVmNames)

    if ($OverwriteExisting) {
        $targetVmNames = Get-NextVmNamesForHostPoolCount `
            -Prefix $VmNamePrefix `
            -Count $SessionHostCount `
            -ExistingHostCount 0
    }
    else {
        $targetVmNames = Get-NextVmNamesForHostPoolCount `
            -Prefix $VmNamePrefix `
            -Count $SessionHostCount `
            -ExistingHostCount $existingHostNames.Count
    }

    Write-Log -Level "INFO" -Component "PLAN" -Message ("Target VM names: {0}" -f ($targetVmNames -join ", "))

    if ($OverwriteExisting) {
        Write-StepBanner -Message "OVERWRITE CLEANUP"

        $toRemove = @(
            $existingHostNames | Where-Object { $_ -like "$VmNamePrefix-*" }
        )

        # Also include target names in case a previous failed run created Hyper-V/Arc resources but not session host objects.
        $toRemove += $targetVmNames
        $toRemove = @($toRemove | Sort-Object -Unique)

        foreach ($vmName in $toRemove) {
            Write-Log -Level "INFO" -Component "CLEANUP" -Message "Cleaning up existing resources for '$vmName'..."

            Remove-SessionHostIfPresent -VmName $vmName
            Remove-ArcMachineIfPresent -VmName $vmName
            Remove-HyperVVmIfPresent -VmName $vmName
            Remove-AdComputerObjectIfRequired -VmName $vmName -DomainJoinCredential $domainJoinCredential
        }
    }

    $registrationToken = $null
    Get-HostPoolRegistrationToken -RegistrationToken ([ref]$registrationToken)

    foreach ($vmName in $targetVmNames) {
        Write-StepBanner -Message "DEPLOY $vmName"

        New-HyperVSessionHostVm `
            -VmName $vmName `
            -TemplatePath $templatePath `
            -GuestLocalAdminCredential $guestLocalAdminCredential

        # For PowerShell Direct, explicitly scope the account to the guest VM's local SAM.
        # Example: hybrid1-01\avdadmin rather than only avdadmin.
        $guestLocalAdminCredentialForVm = New-LocalVmCredentialForPowerShellDirect `
            -VmName $vmName `
            -Credential $guestLocalAdminCredential

        Write-Log -Level "INFO" -Component "GUEST" -Message "Using PowerShell Direct credential username '$($guestLocalAdminCredentialForVm.UserName)'."

        Start-Sleep -Seconds $VmCreationThrottleSeconds

        $psDirectReady = $false

        Wait-ForPowerShellDirect `
            -VmName $vmName `
            -GuestLocalAdminCredential $guestLocalAdminCredentialForVm `
            -TimeoutMinutes $WaitForPowerShellDirectTimeoutMinutes `
            -PollSeconds $WaitForPowerShellDirectPollSeconds `
            -Ready ([ref]$psDirectReady)

        if (-not $psDirectReady) {
            throw "PowerShell Direct did not become available for '$vmName'."
        }

        Invoke-GuestDomainJoin `
            -VmName $vmName `
            -GuestLocalAdminCredential $guestLocalAdminCredentialForVm `
            -DomainJoinCredential $domainJoinCredential

        $domainJoinReady = $false

        Wait-ForDomainJoinRestartAndStability `
            -VmName $vmName `
            -GuestLocalAdminCredential $guestLocalAdminCredentialForVm `
            -TimeoutMinutes $DomainJoinTimeoutMinutes `
            -PollSeconds $PostDomainJoinStablePollSeconds `
            -RequiredStableChecks $PostDomainJoinStableChecks `
            -SettleSeconds $PostDomainJoinSettleSeconds `
            -Ready ([ref]$domainJoinReady)

        if (-not $domainJoinReady) {
            throw "Guest '$vmName' did not become domain joined and stable after restart."
        }

        Install-ArcAgentInGuest `
            -VmName $vmName `
            -GuestLocalAdminCredential $guestLocalAdminCredentialForVm `
            -ServicePrincipalId $arcSpId `
            -ServicePrincipalSecret $arcSpSecret

        $arcFound = $false

        Wait-ForArcMachine `
            -VmName $vmName `
            -Found ([ref]$arcFound)

        if (-not $arcFound) {
            throw "Arc machine '$vmName' did not appear in resource group '$ArcResourceGroupName'."
        }

        Install-AvdArcExtension `
            -VmName $vmName `
            -RegistrationToken $registrationToken

        $registered = $false

        Wait-ForSessionHostRegistration `
            -ExpectedVmName $vmName `
            -TimeoutMinutes $RegistrationTimeoutMinutes `
            -PollSeconds $RegistrationPollSeconds `
            -Registered ([ref]$registered)

        if (-not $registered) {
            throw "Session host '$vmName' did not register in host pool '$HostPoolName' within the timeout."
        }

        Write-Log -Level "SUCCESS" -Component "DEPLOY" -Message "Deployment completed for '$vmName'."
    }

    Write-StepBanner -Message "SUMMARY"
    Write-Output ("SUMMARY | Action=Deployed | Count={0} | Hosts={1} | Template={2}" -f $SessionHostCount, ($targetVmNames -join ","), $templatePath)
    Write-Log -Level "SUCCESS" -Component "RUNBOOK" -Message "Stage 2 AVD Hybrid deployment completed."
}
catch {
    Throw-RunbookError -Step "RUNBOOK" -ErrorRecord $_
}
