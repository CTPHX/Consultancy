<#
.SYNOPSIS
    Stage 2 AVD Hybrid deployment runbook for Hyper-V session hosts.

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
        This is a Stage 2 draft. Test with SessionHostCount = 1 first.
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
$TenantId                              = "00000000-0000-0000-0000-000000000000"

# Subscriptions
# AVD subscription = where the host pool lives.
# Arc subscription = where the Azure Arc-enabled server resources live.
$AvdSubscriptionId                     = "00000000-0000-0000-0000-000000000000"
$ArcSubscriptionId                     = "00000000-0000-0000-0000-000000000000"

# AVD
$HostPoolResourceGroupName             = "rg-avd-hosts-uks"
$HostPoolName                          = "vdpool-avd-prod-uks-desktops"
$RegistrationTokenHours                = 24
$RegistrationTimeoutMinutes            = 30
$RegistrationPollSeconds               = 30

# Azure Arc
$ArcResourceGroupName                  = "rg-avd-hybrid-arc-uks"
$ArcLocation                           = "uksouth"
$ArcCloud                              = "AzureCloud"

# Stage 1 Automation Variables
$CurrentTemplatePathVariableName       = "AVDHybrid-CurrentTemplatePath"
$CurrentGalleryVersionVariableName     = "AVDHybrid-CurrentGalleryVersion"

# Key Vault
# The Key Vault can be in either subscription. Set the subscription it lives in below.
$KeyVaultSubscriptionId                = $AvdSubscriptionId
$KeyVaultName                          = ""

# Guest local administrator
# These credentials are injected into unattend.xml and then used by PowerShell Direct.
$LocalAdminUsernameSecretName           = "adm-local-upn"
$LocalAdminPasswordSecretName           = "adm-local-pw"

# AD DS join
$DomainFqdn                            = "phoenixdemo.co.uk"
$DomainOuPath                          = "OU=AVD,OU=Computers,DC=phoenixdemo,DC=co,DC=uk"
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
$HyperVVmRootPath                       = "D:\Hyper-V\AVDHybrid"
$HyperVSwitchName                       = "AVD-vSwitch"

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

# Azure Arc install inside guest
$ArcAgentDownloadUrl                    = "https://aka.ms/AzureConnectedMachineAgent"
$ArcInstallFolder                       = "C:\AVDHybrid\Arc"
$ArcConnectTimeoutMinutes               = 20
$ArcConnectPollSeconds                  = 30

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

            try {
                $mounted = Mount-VHD -Path $destVhdPath -Passthru
                Start-Sleep -Seconds 3

                $disk = $mounted | Get-Disk
                $partitions = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -ne "Reserved" }

                $windowsDrive = $null

                foreach ($partition in $partitions) {
                    $volume = $null

                    try {
                        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
                    }
                    catch {
                        $volume = $null
                    }

                    if (-not $volume) {
                        continue
                    }

                    if (-not $volume.DriveLetter) {
                        $assignedDriveLetter = Get-FreeDriveLetterLocal

                        Add-PartitionAccessPath `
                            -DiskNumber $disk.Number `
                            -PartitionNumber $partition.PartitionNumber `
                            -AccessPath "$assignedDriveLetter`:\" | Out-Null

                        $volume = Get-Volume -DriveLetter $assignedDriveLetter
                    }

                    $drive = $volume.DriveLetter

                    if ($drive -and (Test-Path "$drive`:\Windows")) {
                        $windowsDrive = $drive
                        break
                    }
                }

                if (-not $windowsDrive) {
                    throw "Unable to find Windows volume inside mounted VHDX."
                }

                $pantherPath = "$windowsDrive`:\Windows\Panther"

                if (-not (Test-Path $pantherPath)) {
                    New-Item -Path $pantherPath -ItemType Directory -Force | Out-Null
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
                Set-Content -Path $unattendPath -Value $unattendXml -Encoding UTF8 -Force

                Write-Output "Injected unattend.xml to '$unattendPath'."
            }
            finally {
                if ($mounted) {
                    Dismount-VHD -Path $destVhdPath
                }
            }
        }

        Write-Output "Creating Hyper-V VM '$VmName'..."

        New-VM `
            -Name $VmName `
            -Generation $Generation `
            -MemoryStartupBytes $MemoryStartupBytes `
            -VHDPath $destVhdPath `
            -Path $vmFolder `
            -SwitchName $SwitchName | Out-Null

        Set-VMProcessor -VMName $VmName -Count $ProcessorCount

        if ($UseDynamicMemory) {
            Set-VMMemory `
                -VMName $VmName `
                -DynamicMemoryEnabled $true `
                -MinimumBytes $MemoryMinimumBytes `
                -StartupBytes $MemoryStartupBytes `
                -MaximumBytes $MemoryMaximumBytes
        }

        Enable-VMIntegrationService -VMName $VmName -Name "Guest Service Interface" -ErrorAction SilentlyContinue

        Start-VM -Name $VmName

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

                if ($env:COMPUTERNAME -ine $ExpectedComputerName) {
                    Rename-Computer -NewName $ExpectedComputerName -Force
                    Restart-Computer -Force
                    return
                }

                if ([string]::IsNullOrWhiteSpace($DomainOuPath)) {
                    Add-Computer `
                        -DomainName $DomainFqdn `
                        -Credential $DomainJoinCredential `
                        -Force `
                        -Restart
                }
                else {
                    Add-Computer `
                        -DomainName $DomainFqdn `
                        -Credential $DomainJoinCredential `
                        -OUPath $DomainOuPath `
                        -Force `
                        -Restart
                }
            } `
            -ArgumentList @($DomainJoinCredential, $DomainFqdn, $DomainOuPath, $VmName)
    }

    Invoke-HyperVHostCommand `
        -ScriptBlock $scriptBlock `
        -ArgumentList @($VmName, $GuestLocalAdminCredential, $DomainJoinCredential, $DomainFqdn, $DomainOuPath) | Out-Null
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

                Write-Output "Downloading Azure Connected Machine Agent..."
                Invoke-WebRequest `
                    -Uri $ArcAgentDownloadUrl `
                    -OutFile $msiPath `
                    -UseBasicParsing

                Write-Output "Installing Azure Connected Machine Agent..."
                $installArgs = "/i `"$msiPath`" /qn /l*v `"$installLog`""
                $install = Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgs -Wait -PassThru

                if ($install.ExitCode -ne 0) {
                    throw "Azure Connected Machine Agent MSI install failed with exit code $($install.ExitCode). Log: $installLog"
                }

                $azcmagent = "C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe"

                if (-not (Test-Path $azcmagent)) {
                    throw "azcmagent.exe was not found at '$azcmagent'."
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

                & $azcmagent @connectArgs

                if ($LASTEXITCODE -ne 0) {
                    throw "azcmagent connect failed with exit code $LASTEXITCODE."
                }

                Write-Output "Azure Arc connection command completed."
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
            )
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

        Start-Sleep -Seconds $VmCreationThrottleSeconds

        $psDirectReady = $false

        Wait-ForPowerShellDirect `
            -VmName $vmName `
            -GuestLocalAdminCredential $guestLocalAdminCredential `
            -TimeoutMinutes $WaitForPowerShellDirectTimeoutMinutes `
            -PollSeconds $WaitForPowerShellDirectPollSeconds `
            -Ready ([ref]$psDirectReady)

        if (-not $psDirectReady) {
            throw "PowerShell Direct did not become available for '$vmName'."
        }

        Invoke-GuestDomainJoin `
            -VmName $vmName `
            -GuestLocalAdminCredential $guestLocalAdminCredential `
            -DomainJoinCredential $domainJoinCredential

        $psDirectReadyAfterJoin = $false

        Wait-ForPowerShellDirect `
            -VmName $vmName `
            -GuestLocalAdminCredential $guestLocalAdminCredential `
            -TimeoutMinutes $DomainJoinTimeoutMinutes `
            -PollSeconds $DomainJoinPollSeconds `
            -Ready ([ref]$psDirectReadyAfterJoin)

        if (-not $psDirectReadyAfterJoin) {
            throw "PowerShell Direct did not return after domain join/restart for '$vmName'."
        }

        Install-ArcAgentInGuest `
            -VmName $vmName `
            -GuestLocalAdminCredential $guestLocalAdminCredential `
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
