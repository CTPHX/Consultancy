<#
 README
 © Phoenix Software 2026
 Developed by Aiden Wright

 PURPOSE
 - Runs from Azure Automation cloud worker
 - Starts Hybrid Worker VM(s) tagged SundayAutomation=Yes
 - Starts the FSLogix cleanup runbook on the Hybrid Worker Group
 - Waits for completion
 - Stops/deallocates the Hybrid Worker VM(s)

 Requirements
 - 'Automation Job Operator' at the storage account level.
 - 'AZ Module' on the Hybrid Worker VM
 - 'Storage Account Contributor' and 'SMB Contributor' at the storage account on the VM Managed Identity
 - 'Microsoft.Storage' Service Endpoint on the Subnet where the Hybrid Worker Vm resides(If no private endpoint)
 - Private Endpooints set up or Hybrid Worker subnet allowed through Storage Account Firewell.
#>

################################################################################################################
# CONFIGURATION
################################################################################################################

$SubscriptionId        = "8ba57a2b-1690-4bee-9e48-6b3d70fd325f"
$AutomationAccountName = "aa-avd-prod-uks-001"
$AutomationRG          = "rg-avd-management-uks"
$HybridWorkerGroupName = "hybrid-worker-avd"
$ChildRunbookName      = "FslogixLegacyProfiledeletion"

$VmTagName  = "SundayAutomation"
$VmTagValue = "Yes"

$VmStartTimeoutSeconds     = 900
$HybridWorkerWarmupSeconds = 300
$JobPollSeconds            = 30

################################################################################################################
# LOGGING
################################################################################################################

function Write-Log {
    param(
        [string]$Message
    )

    Write-Output ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message)
}

function Fail-Step {
    param(
        [string]$Step,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-Log "================ ERROR BEGIN ================"
    Write-Log "FAILED at [$Step]"

    if ($null -ne $ErrorRecord) {
        Write-Log ("Message: " + $ErrorRecord.Exception.Message)

        if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.Line) {
            Write-Log ("Invocation line: " + $ErrorRecord.InvocationInfo.Line)
        }

        Write-Log (($ErrorRecord | Format-List * -Force | Out-String))
    }

    Write-Log "================ ERROR END =================="
    throw $ErrorRecord
}

################################################################################################################
# HELPER - GET VM POWER STATE
################################################################################################################

function Get-VMRunningState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $vm = Get-AzVM `
        -ResourceGroupName $ResourceGroupName `
        -Name $Name `
        -Status `
        -ErrorAction Stop

    $powerState = $vm.Statuses | Where-Object {
        $_.Code -like "PowerState/*"
    } | Select-Object -First 1

    $result = [PSCustomObject]@{
        VmName              = $vm.Name
        ResourceGroupName   = $ResourceGroupName
        PowerStateCode      = $null
        PowerStateDisplay   = $null
        IsRunning           = $false
    }

    if ($null -ne $powerState) {
        $result.PowerStateCode    = $powerState.Code
        $result.PowerStateDisplay = $powerState.DisplayStatus

        if ($powerState.Code -eq "PowerState/running" -or $powerState.DisplayStatus -eq "VM running") {
            $result.IsRunning = $true
        }
    }

    return $result
}

################################################################################################################
# AUTH
################################################################################################################

$ErrorActionPreference = "Stop"

try {
    Write-Log "Runbook starting"
    Write-Log "Authenticating with managed identity"

    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null

    Write-Log "Authenticated successfully"
}
catch {
    Fail-Step "AUTH" $_
}

################################################################################################################
# FIND HYBRID WORKER VMS
################################################################################################################

try {
    Write-Log "Searching for VMs tagged $VmTagName=$VmTagValue"

    $vms = @(Get-AzVM -Status -ErrorAction Stop | Where-Object {
        $_.Tags.ContainsKey($VmTagName) -and $_.Tags[$VmTagName] -eq $VmTagValue
    })

    if ($vms.Count -eq 0) {
        throw "No VMs found with tag $VmTagName=$VmTagValue"
    }

    Write-Log "Found $($vms.Count) VM(s)"

    foreach ($vm in $vms) {
        $powerState = $vm.Statuses | Where-Object {
            $_.Code -like "PowerState/*"
        } | Select-Object -First 1

        $displayState = $null
        $codeState = $null

        if ($null -ne $powerState) {
            $displayState = $powerState.DisplayStatus
            $codeState = $powerState.Code
        }

        Write-Log "Matched VM: $($vm.Name), RG: $($vm.ResourceGroupName), StateCode: $codeState, StateDisplay: $displayState"
    }
}
catch {
    Fail-Step "FIND_HYBRID_WORKER_VMS" $_
}

################################################################################################################
# START VMS, RUN CHILD RUNBOOK, STOP VMS
################################################################################################################

try {
    try {
        ########################################################################################################
        # START HYBRID WORKER VM(S)
        ########################################################################################################

        Write-Log "Starting Hybrid Worker VM(s)"

        foreach ($vm in $vms) {
            $state = Get-VMRunningState `
                -ResourceGroupName $vm.ResourceGroupName `
                -Name $vm.Name

            Write-Log "Current VM state before start: $($state.VmName) = Code: $($state.PowerStateCode), DisplayStatus: $($state.PowerStateDisplay)"

            if ($state.IsRunning) {
                Write-Log "VM already running: $($vm.Name)"
                continue
            }

            Write-Log "Starting VM: $($vm.Name)"

            Start-AzVM `
                -ResourceGroupName $vm.ResourceGroupName `
                -Name $vm.Name `
                -NoWait `
                -ErrorAction Stop
        }

        ########################################################################################################
        # WAIT FOR VM(S) TO BE RUNNING
        ########################################################################################################

        Write-Log "Waiting for VM(s) to reach running state"

        $elapsed = 0

        do {
            Start-Sleep -Seconds 30
            $elapsed += 30

            $runningCount = 0

            foreach ($vm in $vms) {
                $state = Get-VMRunningState `
                    -ResourceGroupName $vm.ResourceGroupName `
                    -Name $vm.Name

                Write-Log "VM state: $($state.VmName) = Code: $($state.PowerStateCode), DisplayStatus: $($state.PowerStateDisplay)"

                if ($state.IsRunning) {
                    $runningCount++
                }
                elseif ([string]::IsNullOrWhiteSpace($state.PowerStateCode)) {
                    Write-Log "WARNING: No PowerState returned for VM: $($state.VmName)"
                }
            }

            Write-Log "Running VM count: $runningCount of $($vms.Count)"
            Write-Log "Elapsed wait time: $elapsed seconds of $VmStartTimeoutSeconds seconds"

        } while ($runningCount -lt $vms.Count -and $elapsed -lt $VmStartTimeoutSeconds)

        if ($runningCount -lt $vms.Count) {
            throw "Timed out waiting for Hybrid Worker VM(s) to start"
        }

        Write-Log "Hybrid Worker VM(s) are running"

        ########################################################################################################
        # WAIT FOR HYBRID WORKER SERVICE
        ########################################################################################################

        Write-Log "Waiting $HybridWorkerWarmupSeconds seconds for Hybrid Worker service availability"
        Start-Sleep -Seconds $HybridWorkerWarmupSeconds

        ########################################################################################################
        # START CHILD RUNBOOK ON HYBRID WORKER GROUP
        ########################################################################################################

        Write-Log "Starting child runbook '$ChildRunbookName' on Hybrid Worker Group '$HybridWorkerGroupName'"

        $job = Start-AzAutomationRunbook `
            -AutomationAccountName $AutomationAccountName `
            -ResourceGroupName $AutomationRG `
            -Name $ChildRunbookName `
            -RunOn $HybridWorkerGroupName `
            -ErrorAction Stop

        Write-Log "Child runbook job started. JobId: $($job.JobId)"

        ########################################################################################################
        # WAIT FOR CHILD RUNBOOK COMPLETION
        ########################################################################################################

        do {
            Start-Sleep -Seconds $JobPollSeconds

            $jobStatus = Get-AzAutomationJob `
                -AutomationAccountName $AutomationAccountName `
                -ResourceGroupName $AutomationRG `
                -Id $job.JobId `
                -ErrorAction Stop

            Write-Log "Child runbook status: $($jobStatus.Status)"

        } while ($jobStatus.Status -in @(
            "New",
            "Activating",
            "Queued",
            "Running",
            "Resuming"
        ))

        if ($jobStatus.Status -ne "Completed") {
            throw "Child runbook finished with status: $($jobStatus.Status)"
        }

        Write-Log "Child runbook completed successfully"
    }
    finally {
        ########################################################################################################
        # STOP / DEALLOCATE HYBRID WORKER VM(S)
        ########################################################################################################

        Write-Log "Stopping/deallocating Hybrid Worker VM(s)"

        foreach ($vm in $vms) {
            try {
                $state = Get-VMRunningState `
                    -ResourceGroupName $vm.ResourceGroupName `
                    -Name $vm.Name

                Write-Log "Current VM state before stop: $($state.VmName) = Code: $($state.PowerStateCode), DisplayStatus: $($state.PowerStateDisplay)"

                if (-not $state.IsRunning) {
                    Write-Log "VM is not running, skipping stop: $($vm.Name)"
                    continue
                }

                Write-Log "Stopping VM: $($vm.Name)"

                Stop-AzVM `
                    -ResourceGroupName $vm.ResourceGroupName `
                    -Name $vm.Name `
                    -Force `
                    -ErrorAction Stop

                Write-Log "Stopped/deallocated VM: $($vm.Name)"
            }
            catch {
                Write-Log "Failed to stop VM: $($vm.Name)"
                Write-Log ("Stop error: " + $_.Exception.Message)
            }
        }
    }
}
catch {
    Fail-Step "ORCHESTRATION" $_
}

Write-Log "Runbook completed"
