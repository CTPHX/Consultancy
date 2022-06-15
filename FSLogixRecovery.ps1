########Configure FSLogix Recovery
#Please import AZ.Accounts & Az.Automation into your AZ Automation Account
#Please see for more infomration https://github.com/Azure/azure-powershell/blob/master/src/Automation/Automation/help/New-AzAutomationSchedule.md

#Variables
$tenantid = ''
$subid = ''
$automationaccount = ''
#RG of Autmation Account
$ResourceGroup = ''
$fspath = '\\this\test'
#Leave Variable Alone
$conn = '$conn'



#Connect to Azure Environment
Connect-AzAccount -Tenant $tenantid -Subscription $subid

#Create Directory
 if (!(test-path -path c:\FSLogix)) {new-item -path c:\FSLogix -itemtype directory}

#Download FSLogix Git
 $ProgressPreference = 'SilentlyContinue'
 Invoke-WebRequest -Uri 'https://github.com/FSLogix/Invoke-FslShrinkDisk/archive/refs/heads/master.zip' -OutFile 'c:\FSlogix\FSLogix.zip'
 $ProgressPreference = 'Continue'

#Expand Archive
 Expand-Archive -Path 'c:\FSlogix\FSLogix.zip' -DestinationPath 'c:\FSlogix'




#Create fslshrink.ps1
  if (!(test-path -path c:\FSlogix\fslshrink.ps1)) {new-item -path c:\FSLogix -name fslshrink.ps1 -ItemType File -Value "
  C:\FSLogix\Invoke-FslShrinkDisk-master\Invoke-FslShrinkDisk.ps1 -Path `"$fspath`" -Recurse -DeleteOlderThanDays 90 -LogPathFile c:\FSLogix\FSLog.csv"
    }

#Create Scheduled task to run fslshrink.ps1
if(Get-ScheduledTask 'FSLogix Shrink' -ErrorAction Ignore) {Write-Output "Scheduled Task already created"} 
else 
{
# Create a new task action
$taskAction = New-ScheduledTaskAction `
    -Execute 'C:\WINDOWS\system32\WindowsPowerShell\v1.0\powershell.exe' `
    -Argument '-ExecutionPolicy Bypass -command "& c:\FSLogix\fslshrink.ps1"'
$taskAction

# Create a new trigger (Startup)
$taskTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At 2am

# The name of your scheduled task.
$taskName = "FSLogix Shrink"

# Describe the scheduled task.
$description = "FSLogix Whitespace recovery."

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $taskAction `
    -Trigger $taskTrigger `
    -Description $description

# Set the task principal's user ID and run level.
$taskPrincipal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
# Set the task compatibility value to Windows 10.
$taskSettings = New-ScheduledTaskSettingsSet -Compatibility Win8
# Update the task principal settings
Set-ScheduledTask -TaskName 'FSLogix Shrink' -Principal $taskPrincipal -Settings $taskSettings
}






#Creates Schedules in Automation Accounts 
$StartTime = (Get-Date "01:30:00").AddDays(1)
New-AzAutomationSchedule -AutomationAccountName $AutomationAccount -Name "Power on AVDMgmt" -StartTime $StartTime -DayOfWeekOccurrence 'First' -DayOfWeek 'Saturday' -MonthInterval '1' -ResourceGroupName $ResourceGroup

$StartTime = (Get-Date "08:00:00").AddDays(1)
New-AzAutomationSchedule -AutomationAccountName $AutomationAccount -Name "Power down AVDMgmt" -StartTime $StartTime -DayOfWeekOccurrence 'First' -DayOfWeek 'Saturday' -MonthInterval '1' -ResourceGroupName $ResourceGroup






#Created Automation Runbook for poweron AVDMgmt and attach schedule
New-AzAutomationRunbook -Name 'PowerOn AVDmgmt' -Type PowerShell -ResourceGroupName $ResourceGroup -AutomationAccountName $automationaccount
#Get-AzAutomationRunbook -ResourceGroupName $ResourceGroup -AutomationAccountName $automationaccount

if (!(test-path -path c:\FSLogix\poweronavd.ps1)) {new-item -path c:\FSLogix -name poweronavd.ps1 -ItemType File -Value "
$conn = Get-AutomationConnection -Name AzureRunAsConnection
Add-AzAccount -ServicePrincipal -Tenant $conn.TenantID -ApplicationID $conn.ApplicationID -CertificateThumbprint $conn.CertificateThumbprint

Start-AzVM -Name 'AVDmgmt' -ResourceGroupName `"$ResourceGroup`"
"
    }
Import-AzAutomationRunbook -Name 'PowerOn AVDmgmt' -ResourceGroupName $ResourceGroup -Path 'c:\FSLogix\poweronavd.ps1' -Type PowerShell -AutomationAccountName $AutomationAccount -Force
Publish-AzAutomationRunbook -AutomationAccountName $AutomationAccount -ResourceGroupName $ResourceGroup -name 'PowerOn AVDmgmt'
#Start-AzAutomationRunbook -AutomationAccountName 'PowerOn AVDmgmt' -ResourceGroupName $ResourceGroup -name 'PowerOn AVDmgmt'
Register-AzAutomationScheduledRunbook -RunbookName 'PowerOn AVDmgmt' -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccount -ScheduleName 'Power on AVDMgmt'






#Created Automation Runbook for poweroff AVDMgmt and attach schedule
New-AzAutomationRunbook -Name 'PowerOff AVDmgmt' -Type PowerShell -ResourceGroupName $ResourceGroup -AutomationAccountName $automationaccount
#Get-AzAutomationRunbook -ResourceGroupName $ResourceGroup -AutomationAccountName $automationaccount

if (!(test-path -path c:\FSLogix\poweroffavd.ps1)) {new-item -path c:\FSLogix -name poweroffavd.ps1 -ItemType File -Value "
$conn = Get-AutomationConnection -Name AzureRunAsConnection
Add-AzAccount -ServicePrincipal -Tenant $conn.TenantID -ApplicationID $conn.ApplicationID -CertificateThumbprint $conn.CertificateThumbprint

Stop-AzVM -Name 'AVDmgmt' -ResourceGroupName `"$ResourceGroup`" -Force
"
    }
Import-AzAutomationRunbook -Name 'PowerOff AVDmgmt' -ResourceGroupName $ResourceGroup -Path 'c:\FSLogix\poweroffavd.ps1' -Type PowerShell -AutomationAccountName $AutomationAccount -Force
Publish-AzAutomationRunbook -AutomationAccountName $AutomationAccount -ResourceGroupName $ResourceGroup -name 'PowerOff AVDmgmt'
#Start-AzAutomationRunbook -AutomationAccountName 'PowerOn AVDmgmt' -ResourceGroupName $ResourceGroup -name 'PowerOn AVDmgmt'
Register-AzAutomationScheduledRunbook -RunbookName 'PowerOff AVDmgmt' -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccount -ScheduleName 'Power down AVDMgmt'



