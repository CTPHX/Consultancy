
Get-ChildItem c:\WVD\Virtual-Desktop-Optimization-Tool-main\*.* | Unblock-File
Set-Location c:\WVD\Virtual-Desktop-Optimization-Tool-main
if ((gwmi win32_computersystem).partofdomain -eq $false) {exit 0}
if (Test-Path "C:\WVD\DONOTDELETE.log") {exit 0}
Set-ExecutionPolicy -ExecutionPolicy ByPass -Force
change logon /drainuntilrestart

start-process cmd -argument "/c C:\WVD\W10-ATP-Onboarding.bat" -Wait -verb 'runas'

Invoke-WebRequest -Uri 'https://nsftwvdblob.blob.core.windows.net/wvdfiles/SophosSetup.exe' -OutFile 'c:\WVD\sophos.exe' -ErrorAction Stop
Start-Process "c:\WVD\sophos.exe" --quiet -Wait

.\Win10_VirtualDesktop_Optimize.ps1 -WindowsVersion 2009 -AcceptEULA -Verbose *> "C:\WVD\DONOTDELETE.log" -Restart
