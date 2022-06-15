Install-Module PSWindowsUpdate
Get-WindowsUpdate -AcceptAll -Install -AutoReboot

#Get-WindowsUpdate -Install -KBArticleID 'KB5007186'