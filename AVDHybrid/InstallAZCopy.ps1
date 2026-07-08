New-Item -Path "C:\Tools\AzCopy" -ItemType Directory -Force | Out-Null

Invoke-WebRequest `
    -Uri "https://aka.ms/downloadazcopy-v10-windows" `
    -OutFile "C:\Tools\AzCopy\azcopy.zip" `
    -UseBasicParsing

Expand-Archive `
    -Path "C:\Tools\AzCopy\azcopy.zip" `
    -DestinationPath "C:\Tools\AzCopy\Extracted" `
    -Force

$azCopyExe = Get-ChildItem `
    -Path "C:\Tools\AzCopy\Extracted" `
    -Recurse `
    -Filter "azcopy.exe" |
    Select-Object -First 1

Copy-Item `
    -Path $azCopyExe.FullName `
    -Destination "C:\Tools\AzCopy\azcopy.exe" `
    -Force

& "C:\Tools\AzCopy\azcopy.exe" --version
