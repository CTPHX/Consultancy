#Run direct on VM in Azure


$ErrorActionPreference = 'Continue'

Write-Output '=============== DOMAIN STATE ==============='

Get-CimInstance Win32_ComputerSystem |
    Select-Object Name, Domain, PartOfDomain |
    Format-List

Write-Output '=============== INSTALLED AVD COMPONENTS ==============='

$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
    Where-Object {
        $_.DisplayName -match 'Remote Desktop.*(Agent|Infrastructure|Boot|SxS|Geneva)'
    } |
    Select-Object DisplayName, DisplayVersion, InstallDate, InstallLocation |
    Sort-Object DisplayName |
    Format-Table -AutoSize

Write-Output '=============== AVD SERVICES ==============='

Get-Service |
    Where-Object {
        $_.Name -match 'RDAgent|RDInfra' -or
        $_.DisplayName -match 'Remote Desktop Agent'
    } |
    Select-Object Name, DisplayName, Status, StartType |
    Format-Table -AutoSize

Write-Output '=============== REGISTRATION STATE ==============='

$agentPath = 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent'

if (Test-Path $agentPath) {
    $agent = Get-ItemProperty $agentPath

    [pscustomobject]@{
        IsRegistered               = $agent.IsRegistered
        RegistrationTokenPresent   = -not [string]::IsNullOrWhiteSpace(
            [string]$agent.RegistrationToken
        )
        RegistrationTokenLength    = ([string]$agent.RegistrationToken).Length
        BrokerResourceIdURI        = $agent.BrokerResourceIdURI
        BrokerResourceIdURIGlobal  = $agent.BrokerResourceIdURIGlobal
    } | Format-List
}
else {
    Write-Output 'RDInfraAgent registry key does not exist.'
}

Write-Output '=============== RECENT AVD/MSI EVENTS ==============='

$startTime = (Get-Date).AddHours(-3)

Get-WinEvent -FilterHashtable @{
    LogName   = 'Application'
    StartTime = $startTime
} -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProviderName -in @(
            'WVD-Agent',
            'WVD-Agent-Updater',
            'RDAgentBootLoader',
            'MsiInstaller'
        ) -or
        $_.Id -in @(3019, 3277, 3703)
    } |
    Select-Object -First 100 TimeCreated, ProviderName, Id,
        LevelDisplayName, Message |
    Format-List

Write-Output '=============== AGENT INSTALL LOG ==============='

$installLog = 'C:\Program Files\Microsoft RDInfra\AgentInstall.txt'

if (Test-Path $installLog) {
    Get-Content $installLog -Tail 150
}
else {
    Write-Output "Agent installation log not found at $installLog"
}

Write-Output '=============== URL TOOL ==============='

$urlTool = Get-ChildItem `
    -Path 'C:\Program Files\Microsoft RDInfra' `
    -Filter 'WVDAgentUrlTool.exe' `
    -Recurse `
    -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($urlTool) {
    Write-Output "Running $($urlTool.FullName)"
    & $urlTool.FullName 2>&1
}
else {
    Write-Output 'WVDAgentUrlTool.exe was not found.'
}

Write-Output '=============== AZURE PLATFORM CONNECTIVITY ==============='

try {
    $metadata = Invoke-RestMethod `
        -Uri 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' `
        -Headers @{ Metadata = 'true' } `
        -TimeoutSec 10

    Write-Output 'Azure Instance Metadata Service: reachable'
    Write-Output "Azure VM name: $($metadata.compute.name)"
}
catch {
    Write-Output "Azure Instance Metadata Service: FAILED - $($_.Exception.Message)"
}

Test-NetConnection login.microsoftonline.com -Port 443 |
    Select-Object ComputerName, RemoteAddress, RemotePort,
        TcpTestSucceeded

Write-Output '=============== RDP SXS STACK ==============='

qwinsta.exe
