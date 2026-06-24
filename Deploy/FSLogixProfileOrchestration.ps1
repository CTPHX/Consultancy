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

$SubscriptionId        = "c5aa488e-459a-4fda-98d8-5115ae28a8b7"
$AutomationAccountName = "YOUR-AUTOMATION-ACCOUNT-NAME"
$AutomationRG          = "YOUR-AUTOMATION-RESOURCE-GROUP"
$HybridWorkerGroupName = "hybrid-worker-avd"
$ChildRunbookName      = "FslogixLegacyProfiledeletion"

$VmTagName  = "SundayAutomation"
$VmTagValue = "Yes"

$VmStartTimeoutSeconds = 900
$HybridWorkerWarmupSeconds = 300
$JobPollSeconds = 30

################################################################################################################
# LOGGING
################################################################################################################

function Write-Log {
    param([string]$Message)

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

    $vms = @(Get-AzVM -Status | Where-Object {
        $_.Tags.ContainsKey($VmTagName) -and $_.Tags[$VmTagName] -eq $VmTagValue
    })

    if ($vms.Count -eq 0) {
        throw "No VMs found with tag $VmTagName=$VmTagValue"
    }

    Write-Log "Found $($vms.Count) VM(s)"

    foreach ($vm in $vms) {
        Write-Log "Matched VM: $($vm.Name), RG: $($vm.ResourceGroupName), State: $($vm.PowerState)"
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
        Write-Log "Starting Hybrid Worker VM(s)"

        foreach ($vm in $vms) {
            if ($vm.PowerState -eq "VM running") {
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

        Write-Log "Waiting for VM(s) to reach running state"

        $elapsed = 0

        do {
            Start-Sleep -Seconds 30
            $elapsed += 30

            $runningCount = 0

            foreach ($vm in $vms) {
                $currentVm = Get-AzVM `
                    -ResourceGroupName $vm.ResourceGroupName `
                    -Name $vm.Name `
                    -Status `
                    -ErrorAction Stop

                Write-Log "VM state: $($currentVm.Name) = $($currentVm.PowerState)"

                if ($currentVm.PowerState -eq "VM running") {
                    $runningCount++
                }
            }

            Write-Log "Running VM count: $runningCount of $($vms.Count)"

        } while ($runningCount -lt $vms.Count -and $elapsed -lt $VmStartTimeoutSeconds)

        if ($runningCount -lt $vms.Count) {
            throw "Timed out waiting for Hybrid Worker VM(s) to start"
        }

        Write-Log "Hybrid Worker VM(s) are running"
        Write-Log "Waiting $HybridWorkerWarmupSeconds seconds for Hybrid Worker service availability"
        Start-Sleep -Seconds $HybridWorkerWarmupSeconds

        Write-Log "Starting child runbook '$ChildRunbookName' on Hybrid Worker Group '$HybridWorkerGroupName'"

        $job = Start-AzAutomationRunbook `
            -AutomationAccountName $AutomationAccountName `
            -ResourceGroupName $AutomationRG `
            -Name $ChildRunbookName `
            -RunOn $HybridWorkerGroupName `
            -ErrorAction Stop

        Write-Log "Child runbook job started. JobId: $($job.JobId)"

        do {
            Start-Sleep -Seconds $JobPollSeconds

            $jobStatus = Get-AzAutomationJob `
                -AutomationAccountName $AutomationAccountName `
                -ResourceGroupName $AutomationRG `
                -Id $job.JobId `
                -ErrorAction Stop

            Write-Log "Child runbook status: $($jobStatus.Status)"

        } while ($jobStatus.Status -in @("New", "Activating", "Queued", "Running", "Resuming"))

        if ($jobStatus.Status -ne "Completed") {
            throw "Child runbook finished with status: $($jobStatus.Status)"
        }

        Write-Log "Child runbook completed successfully"
    }
    finally {
        Write-Log "Stopping/deallocating Hybrid Worker VM(s)"

        foreach ($vm in $vms) {
            try {
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
