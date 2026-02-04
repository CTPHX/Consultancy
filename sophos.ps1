#Create Optimisation script
new-item -path C:\Windows\DigitalServices -name sophos.ps1 -ItemType File -Value '
if ((gwmi win32_computersystem).partofdomain -eq $false) {exit 0}
if (Test-Path "C:\Program Files\Sophos") {exit 0}
Start-Process "C:\Windows\DigitalServices\SophosSetup.exe" --quiet -Wait
'

#Creating Scheduled Task for AVD Optimisation 
if(Get-ScheduledTask 'Sophos Install' -ErrorAction Ignore) {Write-Output "Scheduled Task already created"} 
else 
{
# Create a new task action
$taskAction = New-ScheduledTaskAction `
    -Execute 'C:\WINDOWS\system32\WindowsPowerShell\v1.0\powershell.exe' `
    -Argument '-ExecutionPolicy Bypass -command "& C:\Windows\DigitalServices\sophos.ps1"'
$taskAction

# Create a new trigger (Startup)
$taskTrigger = New-ScheduledTaskTrigger -AtStartup

# Register the new PowerShell scheduled task

# The name of your scheduled task.
$taskName = "Sophos Install"

# Describe the scheduled task.
$description = "Install Sophos on AVD session host."

# Register the scheduled task
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
Set-ScheduledTask -TaskName 'Sophos Install' -Principal $taskPrincipal -Settings $taskSettings
}
