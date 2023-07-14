########################################################
#Set variables
$FSLogixProfilePath1 = "\\stxxxavdfiles01.file.core.windows.net\profiles01"
#$FSLogixProfilePath2 = "\\stxxxavdfiles01.file.core.windows.net\fslogixprofiles02"
#$FSLogixProfilePath3 = "\\stxxxavdfiles01.file.core.windows.net\fsprofiles03"
#$AppAttachPath = "\\stxxxavdfiles01.file.core.windows.net\appattach"

$AADTenantID = "xxxx.xxxx.xxxx.xxxx"
########################################################

########################################################
## Add Languages to running Windows Image for Capture##
########################################################

    Create Local Repository#
   if (!(test-path -path c:\temp)) {new-item -path c:\temp -itemtype directory}
    if (!(test-path -path C:\AVD\Language)) {new-item -path C:\AVD\Language -itemtype directory}
    if (!(test-path -path C:\AVD\Language\en-gb)) {new-item -path C:\AVD\Language\en-gb -itemtype directory}
    
$URLLP = "https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2022-11-23/InstallLanguagePacks.ps1"
$ZIPLP = "LP.ps1"
Invoke-WebRequest -Uri $URLLP -OutFile $ZIPLP -ErrorAction 'Stop'

& .\LP.ps1

##Check If script has been run before##
#if (!(Test-Path "C:\AVD\Language.txt")) {

    ##Disable Language Pack Cleanup##
   # Disable-ScheduledTask -TaskPath "\Microsoft\Windows\AppxDeploymentClient\" -TaskName "Pre-staged app cleanup"
    
    Create Local Repository#
   #if (!(test-path -path c:\temp)) {new-item -path c:\temp -itemtype directory}
    if (!(test-path -path C:\AVD\Language)) {new-item -path C:\AVD\Language -itemtype directory}
    if (!(test-path -path C:\AVD\Language\en-gb)) {new-item -path C:\AVD\Language\en-gb -itemtype directory}
    
    
 # $ProgressPreference = 'SilentlyContinue'
    #Download Language Pack ISO#
   # Invoke-WebRequest -Uri 'https://software-download.microsoft.com/download/pr/19041.1.191206-1406.vb_release_CLIENTLANGPACKDVD_OEM_MULTI.iso' -OutFile 'c:\temp\Language.iso'
    #Download FOD ISO#
  #  Invoke-WebRequest -Uri 'https://software-download.microsoft.com/download/pr/19041.1.191206-1406.vb_release_amd64fre_FOD-PACKAGES_OEM_PT1_amd64fre_MULTI.iso' -OutFile 'c:\temp\FOD.iso'
#$ProgressPreference = 'Continue'

    ##Mount Language ISO##
    
  #  $isoImg = "C:\temp\language.iso"
    ## Drive letter - use desired drive letter
  #  $driveLetter = "X:"
    
    ## Mount the ISO, without having a drive letter auto-assigned
  #  $diskImg = Mount-DiskImage -ImagePath $isoImg  -NoDriveLetter
    
    ## Get mounted ISO volume
   # $volInfo = $diskImg | Get-Volume
    
    ## Mount volume with specified drive letter (requires Administrator access)
   # mountvol $driveLetter $volInfo.UniqueId
   # Start-Sleep -Seconds 10
    # Copy files to C:\AVD
    #Copy-Item "X:\LocalExperiencePack\en-gb\LanguageExperiencePack.en-GB.Neutral.appx" "c:\AVD\language\en-gb"
    #Copy-Item "X:\LocalExperiencePack\en-gb\License.xml" "C:\AVD\language\en-gb"
   # Copy-Item "X:\x64\Langpacks\Microsoft-Windows-Client-Language-Pack_x64_en-gb.cab" "c:\AVD\language"
    
    ##Unmount drive
   # DisMount-DiskImage -ImagePath $isoImg  
    
    ##Mount FOD ISO#
    
  #  $isoImg = "C:\temp\FOD.iso"
    # Drive letter - use desired drive letter
  #  $driveLetter = "Y:"
    
    # Mount the ISO, without having a drive letter auto-assigned
   # $diskImg = Mount-DiskImage -ImagePath $isoImg  -NoDriveLetter
    
    # Get mounted ISO volume
  #  $volInfo = $diskImg | Get-Volume
    
    # Mount volume with specified drive letter (requires Administrator access)
   # mountvol $driveLetter $volInfo.UniqueId
   # Start-Sleep -Seconds 10
    # Copy files to C:\AVD
   # get-childitem -Recurse -path "Y:\" -filter '*en-gb*' | Copy-Item -Destination "C:\AVD\Language"
    
    #Unmount drive
   # DisMount-DiskImage -ImagePath $isoImg
    
    ##Set Language Pack Content Stores##
  #  [string]$LIPContent = "C:\AVD\Language"
    
    ##United Kingdom##
   # Add-AppProvisionedPackage -Online -PackagePath $LIPContent\en-gb\LanguageExperiencePack.en-gb.Neutral.appx -LicensePath $LIPContent\en-gb\License.xml
    #Add-WindowsPackage -Online -PackagePath $LIPContent\Microsoft-Windows-Client-Language-Pack_x64_en-gb.cab
    #Add-WindowsPackage -Online -PackagePath $LIPContent\Microsoft-Windows-LanguageFeatures-Basic-en-gb-Package~31bf3856ad364e35~amd64~~.cab
   # Add-WindowsPackage -Online -PackagePath $LIPContent\Microsoft-Windows-LanguageFeatures-Handwriting-en-gb-Package~31bf3856ad364e35~amd64~~.cab
   # Add-WindowsPackage -Online -PackagePath $LIPContent\Microsoft-Windows-LanguageFeatures-OCR-en-gb-Package~31bf3856ad364e35~amd64~~.cab
   # Add-WindowsPackage -Online -PackagePath $LIPContent\Microsoft-Windows-LanguageFeatures-Speech-en-gb-Package~31bf3856ad364e35~amd64~~.cab
   # Add-WindowsPackage -Online -PackagePath $LIPContent\Microsoft-Windows-LanguageFeatures-TextToSpeech-en-gb-Package~31bf3856ad364e35~amd64~~.cab
    #Add-WindowsPackage -Online -PackagePath $LIPContent\Microsoft-Windows-NetFx3-OnDemand-Package~31bf3856ad364e35~amd64~en-gb~.cab
    #Add-WindowsPackage -Online -PackagePath $LIPContent\Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35~amd64~en-gb~.cab
    #Add-WindowsPackage -Online -PackagePath $LIPContent\Microsoft-Windows-MSPaint-FoD-Package~31bf3856ad364e35~amd64~en-gb~.cab
   # Add-WindowsPackage -Online -PackagePath $LIPContent\Microsoft-Windows-Notepad-FoD-Package~31bf3856ad364e35~amd64~en-gb~.cab
   # Add-WindowsPackage -Online -PackagePath $LIPContent\Microsoft-Windows-PowerShell-ISE-FOD-Package~31bf3856ad364e35~amd64~en-gb~.cab
   # Add-WindowsPackage -Online -PackagePath $LIPContent\Microsoft-Windows-Printing-WFS-FoD-Package~31bf3856ad364e35~amd64~en-gb~.cab
   # Add-WindowsPackage -Online -PackagePath $LIPContent\Microsoft-Windows-StepsRecorder-Package~31bf3856ad364e35~amd64~en-gb~.cab
    #Add-WindowsPackage -Online -PackagePath $LIPContent\Microsoft-Windows-WordPad-FoD-Package~31bf3856ad364e35~amd64~en-gb~.cab
    
    
    #Create region.xml file to set language for new users
   # $RegionalSettings = "C:\AVD\Region.xml"
    
   # if (!(test-path -path c:\AVD\Region.xml)) {new-item -path c:\AVD -name Region.xml -ItemType File -Value '
    #<gs:GlobalizationServices xmlns:gs="urn:longhornGlobalizationUnattend"> 
   # <!--User List-->
   # <gs:UserList>
   #     <gs:User UserID="Current" CopySettingsToDefaultUserAcct="true" CopySettingsToSystemAcct="true"/> 
   # </gs:UserList>
    #<!-- user locale -->
    #<gs:UserLocale> 
    #    <gs:Locale Name="en-GB" SetAsCurrent="true"/> 
    #</gs:UserLocale>
#    <!-- system locale -->
 #   <gs:SystemLocale Name="en-GB"/>
  #  <!-- GeoID -->
   # <gs:LocationPreferences> 
    #    <gs:GeoID Value="242"/> 
    #</gs:LocationPreferences>
    #<gs:MUILanguagePreferences>
    ##       <gs:MUILanguage Value="en-GB"/>
    #       <gs:MUIFallback Value="en-US"/>
    #</gs:MUILanguagePreferences>
    #<!-- input preferences -->
    #<gs:InputPreferences>
    #    <!--en-GB-->
    #    <gs:InputLanguageID Action="add" ID="0809:00000809" Default="true"/> 
    #</gs:InputPreferences>
    #</gs:GlobalizationServices>'
    #}
    
    # Set Locale, language etc. 
  #  & $env:SystemRoot\System32\control.exe "intl.cpl,,/f:`"$RegionalSettings`""
    
    # Set languages/culture. Not needed perse.
 #   Set-WinSystemLocale en-GB
  #  Set-WinUserLanguageList -LanguageList en-GB -Force
   # Set-Culture -CultureInfo en-GB
    #Set-WinHomeLocation -GeoId 242
   # Set-TimeZone -Name "GMT Standard Time"
    
    
    #Write-Output 'language pack installed' | Out-File 'c:\AVD\Language.txt' -Append
    #}
    ############# END OF LANGUAGE PACK INSTALLATION ############



Write-Host '*** AVD Customisation *** Stop the custimization when Error occurs ***'
#$ErroractionPreference='Stop'
$ErroractionPreference='Continue'


#####################################################################################
#This section configures Microsoft best practice settings for AVD#
#####################################################################################

Write-Host '*** AVD Customisation *** START OS CONFIG *** Update the recommended OS configuration ***'

Write-Host '*** AVD Customisation *** SET OS REGKEY *** Prevent Microsoft Edge first run page***'
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\MicrosoftEdge\Main" /v PreventFirstRunPage /t REG_DWORD /d 1 /f

Write-Host '*** AVD Customisation *** SET OS REGKEY *** Specify Start layout for Windows 10 PCs (optional) ***'
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name 'SpecialRoamingOverrideAllowed' -Value '1' -PropertyType DWORD -Force | Out-Null

Write-Host '*** AVD Customisation *** SET OS REGKEY *** Set up time zone redirection ***'
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fEnableTimeZoneRedirection' -Value '1' -PropertyType DWORD -Force | Out-Null

Write-Host '*** AVD Customisation *** SET OS REGKEY *** Disable Storage Sense ***'
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy" /v 01 /t REG_DWORD /d 0 /f
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense' -Name 'AllowStorageSenseGlobal' -Value '0' -PropertyType DWORD -Force | Out-Null

# Note: Remove if not required!
Write-Host '*** AVD Customisation *** SET OS REGKEY *** For feedback hub collection of telemetry data on Windows 10 Enterprise multi-session ***'
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value '3' -PropertyType DWORD -Force | Out-Null

# Note: Remove if not required!
Write-Host '*** AVD Customisation *** SET OS REGKEYS *** Fix 5k resolution support ***'
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'MaxMonitors' -Value '4' -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'MaxXResolution' -Value '5120' -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'MaxYResolution' -Value '2880' -PropertyType DWORD -Force | Out-Null
New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\rdp-sxs' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\rdp-sxs' -Name 'MaxMonitors' -Value '4' -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\rdp-sxs' -Name 'MaxXResolution' -Value '5120' -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\rdp-sxs' -Name 'MaxYResolution' -Value '2880' -PropertyType DWORD -Force | Out-Null


Write-Host '*** AVD Customisation *** CONFIG OFFICE Regkeys *** Set Office Update Notifiations behavior ***'
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' -Name 'hideupdatenotifications' -Value '1' -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' -Name 'hideenabledisableupdates' -Value '1' -PropertyType DWORD -Force | Out-Null


# Onedrive configuration

Write-Host '*** AVD Customisation *** CONFIG ONEDRIVE *** Configure OneDrive to start at sign in for all users. ***'
New-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive' -Value 'C:\Program Files (x86)\Microsoft OneDrive\OneDrive.exe /background' -Force | Out-Null
Write-Host '*** AVD Customisation *** CONFIG ONEDRIVE *** Silently configure user account ***'
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -Name 'SilentAccountConfig' -Value '1' -PropertyType DWORD -Force | Out-Null
#Write-Host '*** AVD Customisation *** CONFIG ONEDRIVE *** Redirect and move Windows known folders to OneDrive by running the following command. ***'
#New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -Name 'KFMSilentOptIn' -Value $AADTenantID -Force | Out-Null

#Write-Host '*** AVD Customisation *** INSTALL *** Install Chocolatey. ***'
#Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))

#Upgrade all Application Packages Installed
#choco upgrade all /y

Write-Host '*** AVD Customisation ********************* END *************************'

Write-Host '*** AVD Customisation *** INSTALL *** AVD Optimisation Script ***'
# Note: This will download and extract the AVD optimization script.
if (!(test-path -path c:\AVD)) {new-item -path c:\AVD -itemtype directory}
Invoke-WebRequest -Uri 'https://github.com/The-Virtual-Desktop-Team/Virtual-Desktop-Optimization-Tool/archive/refs/heads/main.zip' -OutFile 'c:\AVD\master.zip' -ErrorAction Stop
Expand-Archive -Path 'C:\AVD\master.zip' -DestinationPath 'C:\AVD\'  -Force
#create AVD optimisation Script

Start-Sleep -Seconds 10

#Overwriting the AppxPackage.json to configure which UWP are removed during optimisation
(Get-Content -path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json -Raw) -replace 'Unchanged' , 'Disabled' | Set-Content -path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json;

((Get-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json -Raw) -replace 'Microsoft.MSPaint', 'Microsoft.MSPaint_DonNotRemove') | Set-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json
((Get-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json -Raw) -replace 'Microsoft.MicrosoftStickyNotes', 'Microsoft.MicrosoftStickyNotes_DonNotRemove') | Set-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json
((Get-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json -Raw) -replace 'Microsoft.Windows.Photos', 'Microsoft.Windows.Photos_DonNotRemove') | Set-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json
((Get-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json -Raw) -replace 'Microsoft.WindowsAlarms', 'Microsoft.WindowsAlarms_DonNotRemove') | Set-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json
((Get-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json -Raw) -replace 'Microsoft.WindowsCalculator', 'Microsoft.WindowsCalculator_DonNotRemove') | Set-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json
((Get-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json -Raw) -replace 'Microsoft.WindowsCamera', 'Microsoft.WindowsCamera_DonNotRemove') | Set-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json
((Get-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json -Raw) -replace 'Microsoft.WindowsSoundRecorder', 'Microsoft.WindowsSoundRecorder_DonNotRemove') | Set-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json
((Get-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json -Raw) -replace 'Microsoft.ScreenSketch', 'Microsoft.ScreenSketch_DonNotRemove') | Set-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\AppxPackages.json

((Get-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\Services.json -Raw) -replace 'UsoSvc', 'UsoSvc_DonNotStop') | Set-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\Services.json
((Get-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\Services.json -Raw) -replace 'DiagTrack', 'DiagTrack_DonNotStop') | Set-Content -Path C:\AVD\Virtual-Desktop-Optimization-Tool-main\2009\ConfigurationFiles\Services.json

#Create Optimisation script
if (!(test-path -path c:\AVD\optimise.ps1)) {new-item -path c:\AVD -name Optimise.ps1 -ItemType File -Value '
Get-ChildItem c:\AVD\Virtual-Desktop-Optimization-Tool-main\*.* | Unblock-File
Set-Location c:\AVD\Virtual-Desktop-Optimization-Tool-main
if ((gwmi win32_computersystem).partofdomain -eq $false) {exit 0}
if (Test-Path "C:\AVD\DONOTDELETE.log") {exit 0}
Set-ExecutionPolicy -ExecutionPolicy ByPass -Force
change logon /drainuntilrestart
.\Windows_VDOT.ps1 -Optimizations All -AcceptEula -Verbose *> "C:\AVD\DONOTDELETE.log" -Restart
'}

#Creating Scheduled Task for AVD Optimisation 
if(Get-ScheduledTask 'AVD Customisation' -ErrorAction Ignore) {Write-Output "Scheduled Task already created"} 
else 
{
# Create a new task action
$taskAction = New-ScheduledTaskAction `
    -Execute 'C:\WINDOWS\system32\WindowsPowerShell\v1.0\powershell.exe' `
    -Argument '-ExecutionPolicy Bypass -command "& c:\AVD\Optimise.ps1"'
$taskAction

# Create a new trigger (Startup)
$taskTrigger = New-ScheduledTaskTrigger -AtStartup

# Register the new PowerShell scheduled task

# The name of your scheduled task.
$taskName = "AVD Customisation"

# Describe the scheduled task.
$description = "Customise and Optimise a AVD Session Host"

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
Set-ScheduledTask -TaskName 'AVD Customisation' -Principal $taskPrincipal -Settings $taskSettings
}
if (!(test-path -path c:\AVD\FSLogix)) {new-item -path c:\AVD\FSLogix -itemtype directory}
if (!(test-path -path c:\AVD\FSLogix\Redirections.xml)) {new-item -path c:\AVD\FSLogix -name Redirections.xml -ItemType File -Value '
<?xml version="1.0" encoding="UTF-8"?>
<FrxProfileFolderRedirection ExcludeCommonFolders="0">
<Excludes>
<Exclude Copy="0">Downloads</Exclude>
<Exclude Copy="0">AppData\Roaming\Microsoft\Teams\meeting-addin\Cache</Exclude>
<Exclude Copy="0">AppData\Roaming\Microsoft\Teams\media-stack</Exclude>
</Excludes>
<Includes>
<Include Copy="3">AppData\LocalLow\Sun\Java\Deployment\security</Include>
</Includes>
</FrxProfileFolderRedirection>'
}

#Set Windows Defender Exclusions for FSLogix
Add-MpPreference -ExclusionPath "%ProgramFiles%\FSLogix\Apps\frxdrv.sys"
Add-MpPreference -ExclusionPath "%ProgramFiles%\FSLogix\Apps\frxdrvvt.sys"
Add-MpPreference -ExclusionPath "%ProgramFiles%\FSLogix\Apps\frxccd.sys"
Add-MpPreference -ExclusionPath "%TEMP%\*.VHD"
Add-MpPreference -ExclusionPath "%TEMP%\*.VHDX"
Add-MpPreference -ExclusionPath "%Windir%\TEMP\*.VHD"
Add-MpPreference -ExclusionPath "%Windir%\TEMP\*.VHDX"
Add-MpPreference -ExclusionPath "$FSLogixProfilePath1\**.VHD"
Add-MpPreference -ExclusionPath "$FSLogixProfilePath1\**.VHDX"
Add-MpPreference -ExclusionPath "$FSLogixProfilePath2\**.VHD"
Add-MpPreference -ExclusionPath "$FSLogixProfilePath2\**.VHDX"
Add-MpPreference -ExclusionPath "$FSLogixProfilePath3\**.VHD"
Add-MpPreference -ExclusionPath "$FSLogixProfilePath3\**.VHDX"
Add-MpPreference -ExclusionProcess "%ProgramFiles%\FSLogix\Apps\frxccd.exe"
Add-MpPreference -ExclusionProcess "%ProgramFiles%\FSLogix\Apps\frxccds.exe"
Add-MpPreference -ExclusionProcess "%ProgramFiles%\FSLogix\Apps\frxsvc.exe"

#Set Windows Defender Exclusions for App Attach

Add-MpPreference -ExclusionPath "$AppAttachPath\**.VHD"
Add-MpPreference -ExclusionPath "$AppAttachPath\**.VHDX"
Add-MpPreference -ExclusionPath "$AppAttachPath\**.CIM"

Write-Host '*** AVD Customisation *** CONFIG *** Deleting temp folder. ***'
if (test-path -path c:\temp) {
Get-ChildItem -Path 'C:\temp' -Recurse | Remove-Item -Recurse -Force
Remove-Item -Path 'C:\temp' -Force | Out-Null
}
Write-Host '*** AVD Customisation *** CONFIG *** Deleting Language folder. ***'
if (test-path -path c:\AVD\Language) {
Get-ChildItem -Path 'C:\AVD\Language' -Recurse | Remove-Item -Recurse -Force
Remove-Item -Path 'C:\AVD\Language' -Force | Out-Null
}
