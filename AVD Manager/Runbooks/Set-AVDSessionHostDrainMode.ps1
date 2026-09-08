<#
.SYNOPSIS
    Sets Azure Virtual Desktop drain mode for one registered session host.
.DESCRIPTION
    Intended to be started by AVD Manager through Azure Automation. The Automation
    Account managed identity performs the privileged AVD operation. The web app only
    submits a validated job with the target subscription, resource group, host pool,
    session host and desired AllowNewSession state.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$HostPoolName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SessionHostName,

    [Parameter(Mandatory = $true)]
    [bool]$AllowNewSession
)

$ErrorActionPreference = 'Stop'

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.DesktopVirtualization -ErrorAction Stop

Write-Output "Authenticating with the Azure Automation managed identity."
Connect-AzAccount -Identity | Out-Null
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

Write-Output "Validating session host '$SessionHostName' in host pool '$HostPoolName'."
$sessionHost = Get-AzWvdSessionHost `
    -ResourceGroupName $ResourceGroupName `
    -HostPoolName $HostPoolName `
    -Name $SessionHostName

if (-not $sessionHost) {
    throw "Session host '$SessionHostName' was not found in host pool '$HostPoolName'."
}

$desiredMode = if ($AllowNewSession) { 'accepting new sessions' } else { 'drain mode' }
Write-Output "Setting session host '$SessionHostName' to $desiredMode."

Update-AzWvdSessionHost `
    -ResourceGroupName $ResourceGroupName `
    -HostPoolName $HostPoolName `
    -Name $SessionHostName `
    -AllowNewSession:$AllowNewSession | Out-Null

$updated = Get-AzWvdSessionHost `
    -ResourceGroupName $ResourceGroupName `
    -HostPoolName $HostPoolName `
    -Name $SessionHostName

if ($updated.AllowNewSession -ne $AllowNewSession) {
    throw "Azure Virtual Desktop did not report the requested AllowNewSession state after the update."
}

Write-Output "Drain mode update complete. AllowNewSession=$($updated.AllowNewSession)."
